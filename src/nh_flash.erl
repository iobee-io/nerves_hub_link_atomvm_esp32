%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Reading the running packbeam out of flash.
%%
%% The firmware NervesHub manages for an AtomVM device is the packbeam, and the
%% packbeam is in a partition, so a device can report what it is actually
%% running rather than a constant it was compiled with.
%%
%% == Knowing which partition ==
%%
%% AtomVM's `esp32init' records where it booted from in NVS, under `atomvm' /
%% `boot_path', defaulting to `/dev/partition/by-name/main.avm'. So unlike
%% ESP-IDF — where a device cannot ask which of `ota_0'/`ota_1' is live, because
%% AtomVM exposes no `esp_ota_get_running_partition()' — an AtomVM device can
%% read the answer, and stays correct after an update that moved it.
%%
%% `boot_partition/0' reads it. An application may still name a partition
%% explicitly, but it no longer has to.
%%
%% == Reading it ==
%%
%% A partition is much larger than the archive written into it, and the digest
%% NervesHub matches covers the archive alone, so this walks entry by entry to
%% find where the archive ends rather than reading the partition whole.
%%
%% The walk hashes as it goes, with `crypto:hash_init/1' and friends, and keeps
%% only the one entry it needs. Nothing here holds the archive in memory, which
%% matters on a device with a few hundred kilobytes of it.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_flash).

-export([available/0, boot_partition/0, label_from_path/1]).
-export([read_metadata/0, read_metadata/1, verify_signature/2, signature_offset/1]).

%% AtomVM's own NVS namespace, where `esp32init' keeps the boot path.
-define(NVS_NAMESPACE, atomvm).
-define(NVS_BOOT_PATH, boot_path).

%% What `esp32init:get_boot_path/0' falls back to.
-define(DEFAULT_PARTITION, <<"main.avm">>).

%% Bounds how much of the archive is in memory at once.
-define(CHUNK_SIZE, 1024).

%%-----------------------------------------------------------------------------
%% @doc Whether this platform can read flash at all.
%%
%% False everywhere except AtomVM on an ESP32 — on a desktop there is no `esp'
%% module, which is what makes the rest of the library testable off-device.
%% @end
%%-----------------------------------------------------------------------------
-spec available() -> boolean().
available() ->
    erlang:function_exported(esp, partition_read, 3).

%%-----------------------------------------------------------------------------
%% @doc The partition label AtomVM booted this application from.
%%
%% Reads NVS rather than guessing, so it stays right after an update that
%% switched slots. Falls back to the same default `esp32init' uses, which is
%% what a device that has never been switched is running.
%% @end
%%-----------------------------------------------------------------------------
-spec boot_partition() -> binary().
boot_partition() ->
    case nvs_get(?NVS_NAMESPACE, ?NVS_BOOT_PATH) of
        undefined -> ?DEFAULT_PARTITION;
        Path -> label_from_path(Path)
    end.

%%-----------------------------------------------------------------------------
%% @doc Turn the boot path `esp32init' stores into a partition label.
%%
%% It records `/dev/partition/by-name/main.avm', while `esp:partition_read/3'
%% takes `main.avm'. The label is the last component.
%% @end
%%-----------------------------------------------------------------------------
-spec label_from_path(binary() | string()) -> binary().
label_from_path(Path) when is_list(Path) ->
    label_from_path(list_to_binary(Path));
label_from_path(Path) when is_binary(Path) ->
    case [Part || Part <- binary:split(Path, <<"/">>, [global]), Part =/= <<>>] of
        [] -> ?DEFAULT_PARTITION;
        Parts -> lists:last(Parts)
    end.

%%-----------------------------------------------------------------------------
%% @equiv read_metadata(boot_partition())
%% @end
%%-----------------------------------------------------------------------------
-spec read_metadata() -> {ok, map()} | {error, term()}.
read_metadata() ->
    read_metadata(boot_partition()).

%%-----------------------------------------------------------------------------
%% @doc Read and describe the packbeam in the named partition.
%%
%% Returns what `nh_metadata:join_params/1' turns into join parameters.
%% @end
%%-----------------------------------------------------------------------------
-spec read_metadata(binary() | string()) -> {ok, map()} | {error, term()}.
read_metadata(Partition) when is_list(Partition) ->
    read_metadata(list_to_binary(Partition));
read_metadata(Partition) when is_binary(Partition) ->
    case available() of
        false ->
            {error, no_flash_access};
        true ->
            case scan(Partition) of
                {ok, Digest, ApplicationData} ->
                    case nh_packbeam:application_from_data(ApplicationData) of
                        {ok, Application} ->
                            {ok, nh_metadata:describe(Application, nh_metadata:hex(Digest))};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%%-----------------------------------------------------------------------------
%% @doc Check the signature of the archive in a partition.
%%
%% The signed range is every byte before the signature entry begins, and it is
%% mapped rather than read: `esp:partition_mmap/3' hands back a binary that
%% points at flash through the MMU, costing a few words of heap instead of the
%% size of the archive.
%%
%% That is the only way this works on a device. Ed25519 signs a message rather
%% than a digest and there is no incremental verify, so the whole signed range
%% has to be addressable at once -- and an archive can be most of a megabyte
%% while the heap is a few hundred kilobytes.
%%
%% `{error, unsigned}' when the archive carries no signature entry, which the
%% caller decides what to do with.
%% @end
%%-----------------------------------------------------------------------------
-spec verify_signature(binary(), [binary()]) -> {ok, binary()} | {error, term()}.
verify_signature(Partition, PublicKeys) when is_binary(Partition) ->
    case available() of
        false ->
            {error, no_flash_access};
        true ->
            case find_entry(Partition, nh_signature:entry_name()) of
                {ok, Offset, Payload} ->
                    case mmap(Partition, 0, Offset) of
                        {ok, Signed} -> nh_signature:verify_parts(Signed, Payload, PublicKeys);
                        {error, _} = Error -> Error
                    end;
                none ->
                    {error, unsigned};
                {error, _} = Error ->
                    Error
            end
    end.

%%-----------------------------------------------------------------------------
%% @doc Where the signature entry begins, which is where the signed range ends.
%%
%% Exposed because it is the number both ends have to agree on, and a mismatch
%% is otherwise invisible from either side.
%% @end
%%-----------------------------------------------------------------------------
-spec signature_offset(binary()) -> {ok, non_neg_integer()} | none | {error, term()}.
signature_offset(Partition) ->
    case find_entry(Partition, nh_signature:entry_name()) of
        {ok, Offset, _Payload} -> {ok, Offset};
        Other -> Other
    end.

%% Walks headers only, reading one window at a time, so finding an entry near
%% the end of a large archive costs a handful of small reads.
find_entry(Partition, Name) ->
    find_entry(Partition, Name, nh_packbeam:magic_size()).

find_entry(Partition, Name, Offset) ->
    case read(Partition, Offset, nh_packbeam:window_size()) of
        {ok, Window} ->
            case nh_packbeam:entry_header(Window) of
                terminator ->
                    none;
                {ok, #{name := Name, size := Size, data_offset := DataOffset}} ->
                    case read(Partition, Offset + DataOffset, Size - DataOffset) of
                        {ok, Data} -> {ok, Offset, Data};
                        {error, _} = Error -> Error
                    end;
                {ok, #{size := Size}} ->
                    find_entry(Partition, Name, Offset + Size);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

mmap(Partition, Offset, Size) ->
    try apply(esp, partition_mmap, [Partition, Offset, Size]) of
        {ok, Binary} when is_binary(Binary) -> {ok, Binary};
        Binary when is_binary(Binary) -> {ok, Binary};
        error -> {error, {mmap_failed, Partition, Size}};
        Other -> {error, {unexpected_mmap, Other}}
    catch
        _:Reason -> {error, {mmap_failed, Reason}}
    end.

%% Walk the archive from the magic to the terminator, hashing every byte and
%% keeping the application entry's data.
scan(Partition) ->
    MagicSize = nh_packbeam:magic_size(),
    case read(Partition, 0, MagicSize) of
        {ok, Magic} ->
            case Magic =:= nh_packbeam:magic() of
                true ->
                    State = crypto:hash_update(crypto:hash_init(sha256), Magic),
                    walk(Partition, MagicSize, State, undefined);
                false ->
                    {error, not_a_packbeam}
            end;
        {error, _} = Error ->
            Error
    end.

walk(Partition, Offset, State, Application) ->
    case read(Partition, Offset, nh_packbeam:window_size()) of
        {ok, Window} ->
            case nh_packbeam:entry_header(Window) of
                terminator ->
                    finish(Partition, Offset, State, Application);
                {ok, Entry} ->
                    entry(Partition, Offset, Entry, State, Application);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

finish(Partition, Offset, State, Application) ->
    case read(Partition, Offset, nh_packbeam:terminator_size()) of
        {ok, Terminator} ->
            Digest = crypto:hash_final(crypto:hash_update(State, Terminator)),
            case Application of
                undefined -> {error, no_application_metadata};
                _ -> {ok, Digest, Application}
            end;
        {error, _} = Error ->
            Error
    end.

entry(Partition, Offset, Entry, State, Application) ->
    #{size := Size, name := Name, data_offset := DataOffset} = Entry,
    %% The first application spec is the project's own, so a later one never
    %% replaces it.
    Keep = Application =:= undefined andalso nh_packbeam:is_application_entry(Name),

    case consume(Partition, Offset, Size, State, Keep, []) of
        {ok, NextState, Collected} ->
            Next =
                case Keep of
                    true -> binary:part(Collected, DataOffset, Size - DataOffset);
                    false -> Application
                end,
            walk(Partition, Offset + Size, NextState, Next);
        {error, _} = Error ->
            Error
    end.

%% Read `Size' bytes in chunks, hashing each. Chunks are collected only for the
%% one entry that is wanted.
consume(_Partition, _Offset, 0, State, false, _Acc) ->
    {ok, State, undefined};
consume(_Partition, _Offset, 0, State, true, Acc) ->
    {ok, State, iolist_to_binary(lists:reverse(Acc))};
consume(Partition, Offset, Remaining, State, Keep, Acc) ->
    Size = min(Remaining, ?CHUNK_SIZE),
    case read(Partition, Offset, Size) of
        {ok, Chunk} ->
            NextState = crypto:hash_update(State, Chunk),
            NextAcc =
                case Keep of
                    true -> [Chunk | Acc];
                    false -> Acc
                end,
            consume(Partition, Offset + Size, Remaining - Size, NextState, Keep, NextAcc);
        {error, _} = Error ->
            Error
    end.

%% Called through apply/3 so that a build on a platform without the esp module
%% still compiles, rather than failing to load over a call it would never make.
read(Partition, Offset, Size) ->
    try apply(esp, partition_read, [Partition, Offset, Size]) of
        {ok, Binary} when is_binary(Binary) -> {ok, Binary};
        Binary when is_binary(Binary) -> {ok, Binary};
        error -> {error, {partition_read_failed, Partition, Offset, Size}};
        Other -> {error, {unexpected_partition_read, Other}}
    catch
        _:Reason -> {error, {partition_read_failed, Reason}}
    end.

nvs_get(Namespace, Key) ->
    try apply(esp, nvs_get_binary, [Namespace, Key]) of
        Value when is_binary(Value) -> Value;
        _ -> undefined
    catch
        _:_ -> undefined
    end.
