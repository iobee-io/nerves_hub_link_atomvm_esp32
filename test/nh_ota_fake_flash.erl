%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc An `nh_flash' that answers with whatever a test set up.
%%
%% Only the three things `nh_ota' asks it: what is in a slot after a write,
%% whether that slot's signature checks out, and which slot is booted.
-module(nh_ota_fake_flash).

-export([expect/1, expect_signature/1, stop/0]).
-export([read_metadata/1, verify_signature/2, boot_partition/0]).

-define(NAME, ?MODULE).

%% `Metadata' is what `read_metadata/1' will return for any slot.
expect(Metadata) -> expect(Metadata, {ok, a_key}).

expect(Metadata, Signature) ->
    stop(),
    register(?NAME, spawn(fun() -> loop(#{metadata => Metadata, signature => Signature}) end)),
    ok.

expect_signature(Signature) ->
    Metadata = call(metadata),
    expect(Metadata, Signature).

stop() ->
    case whereis(?NAME) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            timer:sleep(1),
            ok
    end.

read_metadata(_Slot) -> {ok, call(metadata)}.

verify_signature(_Slot, _Keys) -> call(signature).

boot_partition() -> <<"main.avm">>.

call(Message) ->
    ?NAME ! {self(), Message},
    receive
        {?NAME, Reply} -> Reply
    after 1000 -> error(fake_flash_timeout)
    end.

loop(State) ->
    receive
        stop ->
            ok;
        {From, What} ->
            From ! {?NAME, maps:get(What, State)},
            loop(State)
    end.
