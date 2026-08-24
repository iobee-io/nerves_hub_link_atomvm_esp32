%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Reading an AtomVM packbeam archive.
%%
%% A packbeam is what AtomVM runs: a flat archive of compiled BEAM modules and
%% data files, mounted by the VM rather than unpacked. It is the firmware
%% NervesHub manages for an AtomVM device — not the ESP-IDF image underneath,
%% which is AtomVM itself and is updated on its own schedule.
%%
%% ```
%% 0x00  "#!/usr/bin/env AtomVM\n\0\0"      24 bytes, doubles as a shebang
%% 0x18  entry, entry, ...                  until the terminator
%%       size:32  flags:32  reserved:32  name\0 (padded to 4)  data
%%       0:32     0:32      0:32         "end\0"
%% '''
%%
%% `size' covers the whole entry, header included, so walking is
%% `Offset + Size'.
%%
%% == Byte length ==
%%
%% NervesHub derives a firmware's UUID from the SHA-256 of the archive as
%% uploaded, so a device reporting a digest has to hash exactly the same bytes.
%% A partition is larger than the archive written into it, which makes the
%% archive's own length the thing that has to be recovered rather than assumed.
%%
%% It is recoverable exactly. `packbeam_api:write_packbeam/2' ends every archive
%% with `create_header(0, 0, &lt;&lt;"end"&gt;&gt;)' — a 12 byte zeroed header
%% followed by a 4 byte `"end\0"' — so the archive ends 16 bytes after the
%% terminator starts. See `byte_length/1'.
%%
%% == Terms ==
%%
%% Application metadata is decoded with `binary_to_term/1'. That is safe here
%% and is not on the server: this reads the device's own firmware, whose atoms
%% are by definition already loaded, while NervesHub reads uploads from anyone
%% and cannot afford to intern atoms out of them.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_packbeam).

-export([magic/0, magic_size/0, header_size/0, terminator_size/0, window_size/0]).
-export([entry_header/1, scan/1, byte_length/1]).
-export([application/1, application_from_data/1, is_application_entry/1]).

-define(MAGIC, <<"#!/usr/bin/env AtomVM\n", 0, 0>>).

%% size, flags, reserved.
-define(HEADER_SIZE, 12).

%% The zeroed header plus the "end\0" that names it.
-define(TERMINATOR_SIZE, 16).

%% Enough of an entry for `entry_header/1' to reach the end of the name. Entry
%% names are relative paths, so this bounds how long one may be.
-define(WINDOW_SIZE, 512).

%% What `entry_header/1' can tell from a window at the start of an entry: how
%% long it is, what it is called, and where its data begins relative to the
%% entry. Not the data itself, which the window may not reach.
-type header() :: #{
    size := pos_integer(),
    flags := non_neg_integer(),
    name := binary(),
    data_offset := pos_integer()
}.

%% What `scan/1' returns, which is a header plus the two things only a walk of
%% the whole archive knows: the entry's data, and where the entry starts.
%%
%% These were one type, and the single type omitted `data'. Everything reading
%% `#{data := _}' then looked unreachable to dialyzer, which reported it as
%% seven "can never match" warnings across this module, `nh_signature' and
%% `nh_metadata' -- none of them real, all of them hiding whatever is.
-type entry() :: #{
    size := pos_integer(),
    flags := non_neg_integer(),
    name := binary(),
    data_offset := pos_integer(),
    data := binary(),
    offset := non_neg_integer()
}.

-export_type([header/0, entry/0]).

%%-----------------------------------------------------------------------------
%% @doc The 24 bytes every packbeam starts with.
%% @end
%%-----------------------------------------------------------------------------
-spec magic() -> binary().
magic() -> ?MAGIC.

-spec magic_size() -> pos_integer().
magic_size() -> byte_size(?MAGIC).

-spec header_size() -> pos_integer().
header_size() -> ?HEADER_SIZE.

-spec terminator_size() -> pos_integer().
terminator_size() -> ?TERMINATOR_SIZE.

%%-----------------------------------------------------------------------------
%% @doc How many bytes `entry_header/1' needs to see.
%%
%% Only relevant when walking a partition a chunk at a time, where the caller
%% chooses how much to read.
%% @end
%%-----------------------------------------------------------------------------
-spec window_size() -> pos_integer().
window_size() -> ?WINDOW_SIZE.

%%-----------------------------------------------------------------------------
%% @doc Parse one entry header.
%%
%% `Bin' starts at the entry and must run to the end of the name — pass
%% `window_size()' bytes, or the rest of the archive if less remains.
%%
%% Returns `terminator' at the end of the archive. A zero size or a zero flags
%% word both end it: the terminator has both, and neither can occur on a real
%% entry.
%% @end
%%-----------------------------------------------------------------------------
-spec entry_header(binary()) -> {ok, header()} | terminator | {error, term()}.
entry_header(<<0:32, _/binary>>) ->
    terminator;
entry_header(<<_Size:32, 0:32, _/binary>>) ->
    terminator;
entry_header(<<Size:32, Flags:32, _Reserved:32, Rest/binary>>) when Size > ?HEADER_SIZE ->
    case binary:match(Rest, <<0>>) of
        {Pos, _} ->
            DataOffset = ?HEADER_SIZE + pad4(Pos + 1),
            case DataOffset < Size of
                true ->
                    {ok, #{
                        size => Size,
                        flags => Flags,
                        name => binary:part(Rest, 0, Pos),
                        data_offset => DataOffset
                    }};
                false ->
                    {error, entry_smaller_than_its_header}
            end;
        nomatch ->
            {error, name_not_terminated}
    end;
entry_header(Bin) when is_binary(Bin), byte_size(Bin) >= ?HEADER_SIZE ->
    %% A size that cannot hold its own header. Malformed, rather than the end of
    %% a well formed archive.
    {error, entry_too_small};
entry_header(_) ->
    {error, truncated}.

%%-----------------------------------------------------------------------------
%% @doc Walk a whole archive, returning every entry in file order.
%%
%% Each entry carries its data. For a partition, where holding the archive in
%% memory is the thing to avoid, walk with `entry_header/1' instead and read
%% only the entry that is wanted.
%% @end
%%-----------------------------------------------------------------------------
-spec scan(binary()) -> {ok, [entry()]} | {error, term()}.
scan(<<Magic:24/binary, Rest/binary>>) when Magic =:= ?MAGIC ->
    scan(Rest, byte_size(?MAGIC), []);
scan(Bin) when is_binary(Bin) ->
    {error, not_a_packbeam}.

scan(Bin, Offset, Acc) ->
    case entry_header(Bin) of
        terminator ->
            {ok, lists:reverse(Acc)};
        {ok, #{size := Size, data_offset := DataOffset} = Entry} when byte_size(Bin) >= Size ->
            Data = binary:part(Bin, DataOffset, Size - DataOffset),
            <<_:Size/binary, Next/binary>> = Bin,
            scan(Next, Offset + Size, [Entry#{data => Data, offset => Offset} | Acc]);
        {ok, _Entry} ->
            {error, truncated_packbeam};
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc The length of the archive itself, ignoring whatever follows it.
%%
%% This is the byte range NervesHub hashed when the archive was uploaded, so it
%% is the range a device has to hash to report a matching digest. See the note
%% above about how it is recovered.
%% @end
%%-----------------------------------------------------------------------------
-spec byte_length(binary()) -> {ok, pos_integer()} | {error, term()}.
byte_length(<<Magic:24/binary, Rest/binary>>) when Magic =:= ?MAGIC ->
    byte_length(Rest, byte_size(?MAGIC));
byte_length(Bin) when is_binary(Bin) ->
    {error, not_a_packbeam}.

byte_length(Bin, Offset) ->
    case entry_header(Bin) of
        terminator ->
            {ok, Offset + ?TERMINATOR_SIZE};
        {ok, #{size := Size}} when byte_size(Bin) >= Size ->
            <<_:Size/binary, Next/binary>> = Bin,
            byte_length(Next, Offset + Size);
        {ok, _Entry} ->
            {error, truncated_packbeam};
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Whether an entry name is an application spec.
%%
%% Matches `atomvm_packbeam:is_application_file/1': the name splits into exactly
%% three components, rather than any path that happens to end the same way.
%% @end
%%-----------------------------------------------------------------------------
-spec is_application_entry(binary()) -> boolean().
is_application_entry(Name) when is_binary(Name) ->
    case binary:split(Name, <<"/">>, [global]) of
        [_App, <<"priv">>, <<"application.bin">>] -> true;
        _ -> false
    end.

%%-----------------------------------------------------------------------------
%% @doc The application this archive is, from a whole archive in memory.
%%
%% The first application spec wins. An archive built from a project with
%% dependencies holds one per application and nothing marks the root, but
%% `atomvm_rebar3_plugin' writes the project's own ahead of the dependency
%% archives it appends, so first is the project's.
%% @end
%%-----------------------------------------------------------------------------
-spec application(binary()) -> {ok, map()} | {error, term()}.
application(Archive) ->
    case scan(Archive) of
        {ok, Entries} ->
            case [E || #{name := Name} = E <- Entries, is_application_entry(Name)] of
                [#{data := Data} | _] -> application_from_data(Data);
                [] -> {error, no_application_metadata}
            end;
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Decode the contents of an `application.bin' entry.
%%
%% A 4 byte length, then `{application, Name, Props}' in the external term
%% format.
%% @end
%%-----------------------------------------------------------------------------
-spec application_from_data(binary()) -> {ok, map()} | {error, term()}.
application_from_data(<<Size:32, Rest/binary>>) when byte_size(Rest) >= Size ->
    Term = binary:part(Rest, 0, Size),
    try binary_to_term(Term) of
        {application, Name, Props} when is_atom(Name), is_list(Props) ->
            {ok, #{
                name => atom_to_binary(Name, latin1),
                vsn => property(vsn, Props),
                description => property(description, Props)
            }};
        _ ->
            {error, malformed_application_metadata}
    catch
        _:_ -> {error, malformed_application_metadata}
    end;
application_from_data(_) ->
    {error, malformed_application_metadata}.

%% `vsn' and `description' are strings in an application spec, which on the wire
%% are lists of bytes.
property(Key, Props) ->
    case lists:keyfind(Key, 1, Props) of
        {Key, Value} when is_list(Value) -> list_to_binary(Value);
        {Key, Value} when is_binary(Value) -> Value;
        _ -> undefined
    end.

pad4(N) ->
    case N rem 4 of
        0 -> N;
        Rem -> N + (4 - Rem)
    end.
