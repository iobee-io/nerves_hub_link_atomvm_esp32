%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Applying a firmware update.
%%
%% NervesHub sends an `update' message naming a URL, a size and a SHA-256. This
%% downloads that archive into the slot the device is not running, checks it,
%% and points the boot path at it. Nothing reboots here — see `nh_slots' for the
%% slot model and `commit/0' and `revert/0' for what happens on the way back up.
%%
%% == Nothing is held in memory ==
%%
%% A packbeam is far larger than the heap an ESP32 has to spare, so the download
%% is streamed: `ahttp_client' hands back `{data, Ref, Bin}' as the socket
%% delivers it, each chunk is buffered only to a flash block, written, hashed
%% and dropped. Peak memory is one block, whatever the archive weighs.
%%
%% == What is checked, and when ==
%%
%% The digest is computed while writing rather than by reading the partition
%% back, so a download that was corrupted in flight is caught. The archive is
%% then read back from flash and walked, which catches a write that did not
%% land. Only after both does the boot path move.
%%
%% Order matters: until the boot path is written the device still boots what it
%% was running, so a failure at any earlier point costs nothing but the
%% download.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ota).

-export([available/0, available/1, apply_update/1, apply_update/2]).
-export([start_update/2, start_update/3]).
-export([pending/0, pending/1, commit/0, commit/1, revert/0, revert/1]).
-export([parse_url/1, digest_matches/2]).

%% Our own NVS namespace. `atomvm' belongs to the loader, and writing our
%% bookkeeping into it would be writing into someone else's keys.
-define(NVS_NAMESPACE, nerves_hub).
-define(NVS_PENDING, pending_slot).
-define(NVS_PREVIOUS, previous_slot).

%% Buffered before each flash write. One erase sector, so writes stay aligned
%% and a chunky download does not turn into hundreds of tiny writes.
-define(BLOCK_SIZE, 4096).

%% How much of the socket to take at once.

-type update_result() :: {ok, binary()} | {error, term()}.

%% The three things here that only exist on a device: flash and NVS through
%% `esp', the download through `ahttp_client', and reading back what was
%% written through `nh_flash'. Each is a module name rather than a direct call,
%% so a test can hand over one that records what it was asked to do.
%%
%% Same idiom as `transport' in `nh_agent', and for the same reason: the
%% install path is the one place in this library where a mistake writes to
%% flash, and it was the least tested because none of it could run off a board.
-define(DEFAULT_ESP, esp).
-define(DEFAULT_HTTP, ahttp_client).
-define(DEFAULT_FLASH, nh_flash).

esp(Opts) -> maps:get(esp, Opts, ?DEFAULT_ESP).
http(Opts) -> maps:get(http, Opts, ?DEFAULT_HTTP).
flash(Opts) -> maps:get(flash, Opts, ?DEFAULT_FLASH).

%%-----------------------------------------------------------------------------
%% @doc Whether this platform can write flash at all.
%% @end
%%-----------------------------------------------------------------------------
-spec available() -> boolean().
available() -> available(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `available/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec available(map()) -> boolean().
available(Opts) ->
    Esp = esp(Opts),
    erlang:function_exported(Esp, partition_write, 3) andalso
        erlang:function_exported(Esp, partition_erase_range, 3).

%%-----------------------------------------------------------------------------
%% @equiv apply_update(Payload, #{})
%% @end
%%-----------------------------------------------------------------------------
-spec apply_update(map()) -> update_result().
apply_update(Payload) -> apply_update(Payload, #{}).

%%-----------------------------------------------------------------------------
%% @doc Download and install an update, returning the slot it was written to.
%%
%% `Payload' is what NervesHub sends: `firmware_url', `size' and `checksum'.
%% `Opts' may carry a `progress' function of one argument, called with a
%% percentage as the download proceeds, and a `slot' to override the target.
%% @end
%%-----------------------------------------------------------------------------
-spec apply_update(map(), map()) -> update_result().
apply_update(Payload, Opts) ->
    case available(Opts) of
        false ->
            {error, no_flash_access};
        true ->
            case target_slot(Opts) of
                {ok, Slot} -> download_into(Slot, Payload, Opts);
                {error, _} = Error -> Error
            end
    end.

target_slot(Opts) ->
    case maps:get(slot, Opts, undefined) of
        undefined -> nh_slots:other((flash(Opts)):boot_partition());
        Slot -> {ok, Slot}
    end.

download_into(Slot, Payload, Opts) ->
    Url = maps:get(<<"firmware_url">>, Payload, maps:get(firmware_url, Payload, undefined)),
    Size = maps:get(<<"size">>, Payload, maps:get(size, Payload, undefined)),
    Checksum = maps:get(<<"checksum">>, Payload, maps:get(checksum, Payload, undefined)),
    Progress = maps:get(progress, Opts, fun(_Percent) -> ok end),

    case parse_url(Url) of
        {ok, Parsed} ->
            case erase(Slot, Size, Opts) of
                ok -> fetch(Slot, Parsed, Size, Checksum, Progress, Opts);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Only what the archive needs, rounded up to a sector. Whatever is left of the
%% old archive beyond it is unreachable: a packbeam ends at its terminator and
%% `nh_packbeam:byte_length/1' stops there.
erase(_Slot, undefined, _Opts) ->
    {error, {missing_update_field, size}};
erase(Slot, Size, Opts) when is_integer(Size), Size > 0 ->
    Sectors = ((Size + ?BLOCK_SIZE - 1) div ?BLOCK_SIZE) * ?BLOCK_SIZE,
    try apply(esp(Opts), partition_erase_range, [Slot, 0, Sectors]) of
        ok -> ok;
        error -> {error, {erase_failed, Slot, Sectors}};
        Other -> {error, {unexpected_erase, Other}}
    catch
        _:Reason -> {error, {erase_failed, Reason}}
    end;
erase(_Slot, Size, _Opts) ->
    {error, {invalid_update_size, Size}}.

fetch(
    Slot,
    #{protocol := Protocol, host := Host, port := Port, path := Path},
    Size,
    Checksum,
    Progress,
    Opts
) ->
    Http = http(Opts),

    %% Passive because AtomVM's `ssl' asserts `{active, false}', and verified
    %% against the bundled CAs. A tampered archive is refused regardless:
    %% `finish/4' checks the sha256 NervesHub sent over the device socket.
    case Http:connect(Protocol, Host, Port, [{active, false}, {verify, verify_peer}]) of
        {ok, Conn} ->
            case Http:request(Conn, <<"GET">>, Path, [], undefined) of
                {ok, Conn2, _Ref} ->
                    State = #{
                        slot => Slot,
                        keys => maps:get(keys, Opts, []),
                        opts => Opts,
                        offset => 0,
                        written => 0,
                        buffer => <<>>,
                        hash => crypto:hash_init(sha256),
                        size => Size,
                        progress => Progress,
                        reported => -1,
                        status => undefined
                    },
                    Result = recv_loop(Conn2, State),
                    _ = Http:close(Conn2),
                    finish(Result, Slot, Checksum, Opts);
                {error, Reason} ->
                    _ = Http:close(Conn),
                    {error, {request_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {connect_failed, Reason}}
    end.

recv_loop(Conn, #{opts := Opts} = State) ->
    Http = http(Opts),

    case Http:recv(Conn, 0) of
        {ok, Conn2, Responses} ->
            case handle(Responses, State) of
                {done, Final} -> flush(Final);
                {continue, Next} -> recv_loop(Conn2, Next);
                {error, _} = Error -> Error
            end;
        %% Passive mode reports a peer close as an error even when the response
        %% was complete, which is how a body with no length ends.
        {error, {_Transport, closed}} ->
            flush(State);
        {error, Reason} ->
            {error, {stream_failed, Reason}}
    end.

handle([], State) ->
    {continue, State};
handle([{status, _Ref, Status} | Rest], State) ->
    case Status of
        200 -> handle(Rest, State#{status => 200});
        Other -> {error, {http_status, Other}}
    end;
handle([{header, _Ref, _Header} | Rest], State) ->
    handle(Rest, State);
handle([{trailer_header, _Ref, _Header} | Rest], State) ->
    handle(Rest, State);
handle([{data, _Ref, Chunk} | Rest], State) ->
    case write(Chunk, State) of
        {ok, Next} -> handle(Rest, Next);
        {error, _} = Error -> Error
    end;
handle([{done, _Ref} | _Rest], State) ->
    {done, State}.

%% Buffer to a block, write whole blocks, keep the remainder. The hash covers
%% the bytes as they arrive, so it catches corruption in flight rather than
%% re-reading what was just written.
write(Chunk, #{buffer := Buffer, hash := Hash} = State) ->
    Combined = <<Buffer/binary, Chunk/binary>>,
    Next = State#{hash => crypto:hash_update(Hash, Chunk)},
    case emit_blocks(Combined, Next) of
        {ok, Emitted} -> {ok, report(Emitted)};
        {error, _} = Error -> Error
    end.

emit_blocks(Buffer, State) when byte_size(Buffer) < ?BLOCK_SIZE ->
    {ok, State#{buffer => Buffer}};
emit_blocks(Buffer, #{slot := Slot, offset := Offset, opts := Opts} = State) ->
    <<Block:?BLOCK_SIZE/binary, Rest/binary>> = Buffer,
    case partition_write(Slot, Offset, Block, Opts) of
        ok ->
            emit_blocks(Rest, State#{
                offset => Offset + ?BLOCK_SIZE,
                written => maps:get(written, State) + ?BLOCK_SIZE
            });
        {error, _} = Error ->
            Error
    end.

%% The tail, which will not be a whole block. Flash writes want a multiple of
%% four bytes, so it is padded; the archive's own length is what bounds it when
%% it is read back, not the partition's.
flush(#{buffer := Buffer, slot := Slot, offset := Offset, opts := Opts} = State) when
    byte_size(Buffer) > 0
->
    Padded = pad4(Buffer),
    case partition_write(Slot, Offset, Padded, Opts) of
        ok ->
            {ok, State#{
                buffer => <<>>,
                offset => Offset + byte_size(Padded),
                written => maps:get(written, State) + byte_size(Buffer)
            }};
        {error, _} = Error ->
            Error
    end;
flush(State) ->
    {ok, State}.

finish({ok, State}, Slot, Checksum, Opts) ->
    #{hash := Hash, written := Written, keys := Keys} = State,
    Digest = nh_metadata:hex(crypto:hash_final(Hash)),

    case digest_matches(Digest, Checksum) of
        true -> verify_and_arm(Slot, Written, Digest, Keys, Opts);
        false -> {error, {checksum_mismatch, Digest, Checksum}}
    end;
finish({error, _} = Error, _Slot, _Checksum, _Opts) ->
    Error.

%% Read it back before arming it. The digest proves what arrived over the wire;
%% this proves what actually landed in flash.
verify_and_arm(Slot, Written, Digest, Keys, Opts) ->
    case (flash(Opts)):read_metadata(Slot) of
        {ok, Metadata} ->
            case maps:get(avm_sha256, Metadata) of
                Digest -> check_signature(Slot, Metadata, Written, Keys, Opts);
                Other -> {error, {written_archive_mismatch, Other, Digest}}
            end;
        {error, Reason} ->
            {error, {unreadable_after_write, Reason}}
    end.

%% Configuring keys is what asks for signatures. A device with none has nothing
%% to check against and installs what NervesHub sent it; a device with keys
%% refuses anything they do not cover, including an archive carrying no
%% signature at all.
%%
%% This runs before the boot path moves, so a rejected archive sits in a slot
%% nothing boots from and the device keeps running what it had.
check_signature(Slot, Metadata, Written, [], Opts) ->
    arm(Slot, Metadata, Written, Opts);
check_signature(Slot, Metadata, Written, Keys, Opts) ->
    case (flash(Opts)):verify_signature(Slot, Keys) of
        {ok, _Key} ->
            arm(Slot, Metadata, Written, Opts);
        {error, verification_unavailable} ->
            %% Keys were configured, so signatures were asked for, and this VM
            %% cannot check them -- see `nh_signature:available/0'. Installing
            %% anyway would quietly drop the guarantee the keys were there to
            %% provide.
            {error, {signature_rejected, verification_unavailable}};
        {error, Reason} ->
            {error, {signature_rejected, Reason}}
    end.

%% The boot path moves last, and the trial markers are written before it: a
%% device that loses power between the two boots what it was already running,
%% while one that loses power after has the markers it needs to reverse the
%% move.
arm(Slot, _Metadata, _Written, Opts) ->
    Previous = (flash(Opts)):boot_partition(),

    with_ok(
        [
            fun() -> nvs_put(?NVS_PREVIOUS, Previous, Opts) end,
            fun() -> nvs_put(?NVS_PENDING, Slot, Opts) end,
            fun() -> nvs_put_atomvm_boot_path(nh_slots:boot_path(Slot), Opts) end
        ],
        Slot
    ).

with_ok([], Result) ->
    {ok, Result};
with_ok([Step | Rest], Result) ->
    case Step() of
        ok -> with_ok(Rest, Result);
        {error, _} = Error -> Error
    end.

%%-----------------------------------------------------------------------------
%% @doc The slot a reboot is on trial for, if any.
%%
%% Set by an update and cleared by `commit/0'. A device that finds one here is
%% running firmware that has not yet proved itself.
%% @end
%%-----------------------------------------------------------------------------
-spec pending() -> {ok, binary()} | none.
pending() -> pending(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `pending/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec pending(map()) -> {ok, binary()} | none.
pending(Opts) ->
    case nvs_get(?NVS_PENDING, Opts) of
        undefined -> none;
        Slot -> {ok, Slot}
    end.

%%-----------------------------------------------------------------------------
%% @doc Accept the running firmware, so it is no longer on trial.
%%
%% Called once the device has done something that proves the update worked —
%% joining NervesHub is the evidence this library uses, because an update that
%% cannot reach the server is one nothing could recover from remotely.
%% @end
%%-----------------------------------------------------------------------------
-spec commit() -> ok | {error, term()}.
commit() -> commit(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `commit/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec commit(map()) -> ok | {error, term()}.
commit(Opts) ->
    case nvs_erase(?NVS_PENDING, Opts) of
        ok -> nvs_erase(?NVS_PREVIOUS, Opts);
        {error, _} = Error -> Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Point the boot path back at the firmware that was running before.
%%
%% Does not reboot. The caller decides when, because reverting mid-flight and
%% rebooting immediately would cut off whatever it was trying to report.
%% @end
%%-----------------------------------------------------------------------------
-spec revert() -> {ok, binary()} | {error, term()}.
revert() -> revert(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `revert/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec revert(map()) -> {ok, binary()} | {error, term()}.
revert(Opts) ->
    case nvs_get(?NVS_PREVIOUS, Opts) of
        undefined ->
            {error, nothing_to_revert_to};
        Previous ->
            case nvs_put_atomvm_boot_path(nh_slots:boot_path(Previous), Opts) of
                ok ->
                    _ = commit(Opts),
                    {ok, Previous};
                {error, _} = Error ->
                    Error
            end
    end.

%%-----------------------------------------------------------------------------
%% @doc Run an update in its own process, reporting back to the caller.
%%
%% The download takes as long as it takes, and the agent has heartbeats to send
%% while it runs — so it does not run on the agent's process. The caller
%% receives `{nh_ota, self(), {progress, Percent}}' as it goes and
%% `{nh_ota, self(), Result}' at the end.
%% @end
%%-----------------------------------------------------------------------------
-spec start_update(map(), pid()) -> pid().
start_update(Payload, Owner) ->
    start_update(Payload, Owner, #{}).

%%-----------------------------------------------------------------------------
%% @doc As `start_update/2', with options for `apply_update/2'.
%% @end
%%-----------------------------------------------------------------------------
-spec start_update(map(), pid(), map()) -> pid().
start_update(Payload, Owner, Opts) ->
    %% Monitored, not just spawned. A download that dies without sending a
    %% result would otherwise leave the agent waiting for one forever, and the
    %% platform seeing an update that started and never finished.
    {Pid, _Ref} =
        spawn_monitor(fun() ->
            Self = self(),
            Progress = fun(Percent) -> Owner ! {nh_ota, Self, {progress, Percent}} end,
            Owner ! {nh_ota, Self, apply_update(Payload, Opts#{progress => Progress})}
        end),

    Pid.

%%-----------------------------------------------------------------------------
%% @doc Compare a computed digest against the one NervesHub sent.
%%
%% Case insensitive: NervesHub stores a firmware checksum upper case and this
%% library works in lower case, and a comparison that failed on that alone
%% would reject every good download.
%% @end
%%-----------------------------------------------------------------------------
-spec digest_matches(binary(), binary() | undefined) -> boolean().
digest_matches(_Digest, undefined) -> false;
digest_matches(Digest, Checksum) when is_binary(Checksum) -> lower(Digest) =:= lower(Checksum);
digest_matches(_Digest, _Checksum) -> false.

lower(Bin) -> <<<<(lower_char(C))>> || <<C>> <= Bin>>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

%%-----------------------------------------------------------------------------
%% @doc Split a firmware URL into what `ahttp_client:connect/4' takes.
%%
%% Deliberately small: NervesHub hands out ordinary absolute URLs, and a full
%% URI parser is not something to carry onto a device for that.
%% @end
%%-----------------------------------------------------------------------------
-spec parse_url(binary() | string() | undefined) -> {ok, map()} | {error, term()}.
parse_url(undefined) ->
    {error, {missing_update_field, firmware_url}};
parse_url(Url) when is_list(Url) ->
    parse_url(list_to_binary(Url));
parse_url(<<"http://", Rest/binary>>) ->
    split_authority(http, 80, Rest);
parse_url(<<"https://", Rest/binary>>) ->
    split_authority(https, 443, Rest);
parse_url(Url) ->
    {error, {unsupported_url, Url}}.

split_authority(Protocol, DefaultPort, Rest) ->
    {Authority, Path} =
        case binary:match(Rest, <<"/">>) of
            {Pos, _} ->
                {binary:part(Rest, 0, Pos), binary:part(Rest, Pos, byte_size(Rest) - Pos)};
            nomatch ->
                {Rest, <<"/">>}
        end,

    case binary:split(Authority, <<":">>) of
        [Host] when byte_size(Host) > 0 ->
            {ok, #{protocol => Protocol, host => Host, port => DefaultPort, path => Path}};
        [Host, PortBin] when byte_size(Host) > 0 ->
            case port_number(PortBin) of
                {ok, Port} ->
                    {ok, #{protocol => Protocol, host => Host, port => Port, path => Path}};
                error ->
                    {error, {invalid_port, PortBin}}
            end;
        _ ->
            {error, {invalid_url_authority, Authority}}
    end.

port_number(Bin) ->
    try binary_to_integer(Bin) of
        Port when Port > 0, Port =< 65535 -> {ok, Port};
        _ -> error
    catch
        _:_ -> error
    end.

%% Percentages only, and only when one changes, so a large download does not
%% turn into hundreds of messages to the server.
report(#{size := Size, written := Written, reported := Reported, progress := Progress} = State) when
    is_integer(Size), Size > 0
->
    Percent = min(100, (Written * 100) div Size),
    case Percent > Reported of
        true ->
            _ = Progress(Percent),
            State#{reported => Percent};
        false ->
            State
    end;
report(State) ->
    State.

pad4(Bin) ->
    case byte_size(Bin) rem 4 of
        0 -> Bin;
        Rem -> <<Bin/binary, 0:((4 - Rem) * 8)>>
    end.

partition_write(Slot, Offset, Data, Opts) ->
    try apply(esp(Opts), partition_write, [Slot, Offset, Data]) of
        ok -> ok;
        error -> {error, {write_failed, Slot, Offset}};
        Other -> {error, {unexpected_write, Other}}
    catch
        _:Reason -> {error, {write_failed, Reason}}
    end.

nvs_put_atomvm_boot_path(Path, Opts) ->
    try apply(esp(Opts), nvs_set_binary, [atomvm, boot_path, Path]) of
        ok -> ok;
        Other -> {error, {boot_path_not_set, Other}}
    catch
        _:Reason -> {error, {boot_path_not_set, Reason}}
    end.

nvs_put(Key, Value, Opts) ->
    try apply(esp(Opts), nvs_set_binary, [?NVS_NAMESPACE, Key, Value]) of
        ok -> ok;
        Other -> {error, {nvs_write_failed, Key, Other}}
    catch
        _:Reason -> {error, {nvs_write_failed, Key, Reason}}
    end.

nvs_get(Key, Opts) ->
    try apply(esp(Opts), nvs_get_binary, [?NVS_NAMESPACE, Key]) of
        Value when is_binary(Value) -> Value;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% `esp:nvs_erase_key/2' returns `ok' and does nothing when the key is not
%% there, so "already gone" needs no special case here. Anything else is a
%% failure worth reporting: swallowing it would let `commit/0' report a commit
%% that did not happen, leaving the pending marker on flash while the device
%% believes the firmware is validated.
nvs_erase(Key, Opts) ->
    try apply(esp(Opts), nvs_erase_key, [?NVS_NAMESPACE, Key]) of
        ok -> ok;
        Other -> {error, {nvs_erase_failed, Key, Other}}
    catch
        _:Reason -> {error, {nvs_erase_failed, Key, Reason}}
    end.
