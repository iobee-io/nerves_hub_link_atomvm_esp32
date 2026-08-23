%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The device agent: socket, channel, heartbeat, and dispatch.
%%
%% This is the only process. `nh_channel' holds the protocol and `nh_metadata'
%% reads the firmware description; both are pure, and this loop is what gives
%% them a socket and a clock.
%%
%% == The transport ==
%%
%% The transport is a module, not a hard dependency, so the agent can be driven
%% on a desktop against a real NervesHub before it runs on a chip:
%%
%% ```
%% Transport:open(Config)             -> {ok, Handle} | {error, term()}
%% Transport:send_text(Handle, Binary) -> ok | {error, term()}
%% Transport:close(Handle)            -> ok
%% '''
%%
%% and it delivers `{websocket, Handle, connected | {text, B} | {closed, R} |
%% {error, R}}'. `websocket_client' from atomvm_websocket_client already has
%% this shape.
%%
%% == Reconnection ==
%%
%% The transport reconnects on its own, so `connected' arrives more than once.
%% Every one of them starts a fresh channel join, because a Phoenix channel does
%% not survive a socket reconnect. This is the whole reason the agent watches for
%% `connected' rather than joining once at startup.
%%
%% == Heartbeats ==
%%
%% NervesHub closes a socket that stops sending heartbeats. The deadline is kept
%% as an absolute time rather than a `receive ... after' timeout, so a steady
%% stream of incoming messages cannot keep pushing the heartbeat out and get the
%% device disconnected while it looks busy and healthy.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_agent).

-export([start/1, start_link/1, stop/1]).

%% Exported so a supervisor or a test can run the loop directly.
-export([init/2, loop/1]).

%% Long enough for a frame to leave the socket, short enough that an operator
%% does not notice.
-define(REBOOT_GRACE_MS, 250).

-define(DEFAULT_HEARTBEAT_MS, 30000).

-type config() :: #{
    url => binary() | string(),
    host => binary() | string(),
    identifier := binary(),
    transport => module(),
    shared_secret => {binary(), binary()},
    client_cert => {binary(), binary()},
    verify => term(),
    metadata => map(),
    handler => pid(),
    heartbeat_ms => pos_integer()
}.

-export_type([config/0]).

%%-----------------------------------------------------------------------------
%% @doc Start the agent, linked to the caller.
%% @end
%%-----------------------------------------------------------------------------
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    Owner = maps:get(handler, Config, self()),
    named(spawn_link(?MODULE, init, [Config, Owner]), Config).

-spec start(config()) -> {ok, pid()} | {error, term()}.
start(Config) ->
    Owner = maps:get(handler, Config, self()),
    named(spawn(?MODULE, init, [Config, Owner]), Config).

%% `register => Name' gives the agent a name so that something configured
%% before it existed can find it later -- `nh_logger' is the reason, since a
%% `logger' handler is set up at startup and the agent connects afterwards.
%%
%% A name already taken is an error rather than something to take over: the
%% holder may be a working agent, and stealing its name would leave logs going
%% to a process nothing else can reach.
named(Pid, Config) ->
    case maps:get(register, Config, undefined) of
        undefined ->
            {ok, Pid};
        Name when is_atom(Name) ->
            try
                true = register(Name, Pid),
                {ok, Pid}
            catch
                _:_ ->
                    Pid ! stop,
                    {error, {name_taken, Name}}
            end;
        Other ->
            Pid ! stop,
            {error, {invalid_register, Other}}
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

%% @private
init(Config, Owner) ->
    Transport = maps:get(transport, Config, websocket_client),
    HeartbeatMs = maps:get(heartbeat_ms, Config, ?DEFAULT_HEARTBEAT_MS),
    Params = maybe_request_keys(join_params(Config), Config),
    Extensions = nh_extensions:new(Config),

    Channel =
        maybe_add_extensions(maybe_add_console(nh_channel:new(Params), Config), Extensions),

    case open(Transport, Config) of
        {ok, Handle} ->
            loop(#{
                transport => Transport,
                handle => Handle,
                owner => Owner,
                updates => maps:get(updates, Config, auto),
                firmware_keys => stash_keys(maps:get(firmware_keys, Config, [])),
                reboot => maps:get(reboot, Config, auto),
                channel => Channel,
                console => nh_console:new(),
                extensions => Extensions,
                heartbeat_ms => HeartbeatMs,
                %% No heartbeats until the socket is up.
                heartbeat_at => infinity
            });
        {error, Reason} ->
            Owner ! {nerves_hub, {transport_error, Reason}},
            exit({transport_error, Reason})
    end.

%% A config the URL cannot be built from is reported the same way a refused
%% connection is, rather than crashing on a badmatch here. `nerves_hub_link'
%% catches it earlier; this is the path for using the agent directly.
open(Transport, Config) ->
    case nh_url:resolve(Config) of
        {ok, Url} -> Transport:open(transport_config(Config, Url));
        {error, _} = Error -> Error
    end.

%% @private
loop(#{heartbeat_at := HeartbeatAt} = State) ->
    Timeout = timeout_until(HeartbeatAt),

    receive
        {websocket, _Handle, connected} ->
            %% A fresh join on every connection, including reconnections.
            {Channel, Actions} = nh_channel:connected(maps:get(channel, State)),
            State1 = run(Actions, State#{channel => Channel}),
            loop(schedule_heartbeat(State1));
        {websocket, _Handle, {text, Text}} ->
            {Channel, Actions} = nh_channel:handle_text(Text, maps:get(channel, State)),
            loop(run(Actions, State#{channel => Channel}));
        {websocket, _Handle, {closed, Reason}} ->
            notify(State, {disconnected, Reason}),
            %% The join is gone with the socket, but the channel is not rebuilt:
            %% that would restart reference numbering and drop the join
            %% parameters, so a reconnected device would report no firmware at
            %% all. The transport reconnects and `connected' joins again.
            Channel = nh_channel:disconnected(maps:get(channel, State)),
            loop(State#{channel => Channel, heartbeat_at => infinity});
        {websocket, _Handle, {error, Reason}} ->
            notify(State, {transport_error, Reason}),
            loop(State);
        {nh_ext_geo, _Pid, Location} ->
            loop(push_extension(nh_ext_geo:event(), Location, State));
        {'DOWN', _Ref, process, Pid, Reason} ->
            loop(updater_down(Pid, Reason, State));
        {nh_ota, _Pid, {progress, Percent}} ->
            loop(
                push_event(
                    <<"update_progress">>,
                    #{<<"value">> => Percent, <<"stage">> => <<"downloading">>},
                    State
                )
            );
        {nh_ota, _Pid, {ok, Slot}} ->
            %% Written and armed, not yet running. Rebooting is the
            %% application's call: it may have work to finish first, and a
            %% library that restarts a device on its own is a library that
            %% surprises someone.
            notify(State, {update_ready, Slot}),
            loop(maps:remove(update, State));
        {nh_ota, _Pid, {error, Reason}} ->
            notify(State, {update_failed, Reason}),
            State1 = push_event(
                <<"status_update">>,
                #{<<"status">> => <<"failed">>, <<"reason">> => describe(Reason)},
                State
            ),
            loop(maps:remove(update, State1));
        {push_extension, Event, Payload} ->
            loop(push_extension(Event, Payload, State));
        {push, Event, Payload} ->
            {Channel, Actions} = nh_channel:push(Event, Payload, maps:get(channel, State)),
            loop(run(Actions, State#{channel => Channel}));
        stop ->
            Transport = maps:get(transport, State),
            Transport:close(maps:get(handle, State)),
            ok;
        Other ->
            notify(State, {unexpected, Other}),
            loop(State)
    after Timeout ->
        {Channel, Actions} = nh_channel:heartbeat(maps:get(channel, State)),
        State1 = run(Actions, State#{channel => Channel}),
        loop(schedule_heartbeat(State1))
    end.

%% ------------------------------------------------------------------- internals

run(Actions, State) ->
    lists:foldl(fun run_action/2, State, Actions).

run_action({send, Frame}, State) ->
    Transport = maps:get(transport, State),
    case Transport:send_text(maps:get(handle, State), Frame) of
        ok ->
            State;
        {error, Reason} ->
            notify(State, {send_failed, Reason}),
            State
    end;
run_action({event, Event}, State) ->
    handle_event(Event, State).

%% The device topic is the one the owner hears about unqualified, because it is
%% the one that means "this device is talking to NervesHub". Any other topic is
%% reported by name.
handle_event({joined, <<"device">>, Response}, State) ->
    notify(State, {joined, Response}),
    validate_pending(State);
handle_event({joined, <<"extensions">>, Response}, State) ->
    {Extensions, Actions} = nh_extensions:attach(Response, maps:get(extensions, State)),
    notify(State, {extensions_attached, nh_extensions:attached(Extensions)}),
    run_extension_actions(Actions, State#{extensions => Extensions});
handle_event({message, <<"extensions">>, Event, Payload}, State) ->
    {Extensions, Actions} = nh_extensions:handle_event(Event, Payload, maps:get(extensions, State)),
    run_extension_actions(Actions, State#{extensions => Extensions});
handle_event({joined, <<"console">>, _Response}, State) ->
    notify(State, console_joined),
    console_out(nh_console:banner(), State);
handle_event({joined, Topic, Response}, State) ->
    notify(State, {joined, Topic, Response}),
    State;
handle_event({join_error, <<"device">>, Reason}, State) ->
    notify(State, {join_error, Reason}),
    State;
handle_event({join_error, Topic, Reason}, State) ->
    notify(State, {join_error, Topic, Reason}),
    State;
handle_event({message, <<"console">>, <<"dn">>, Payload}, State) ->
    Data = maps:get(<<"data">>, Payload, <<>>),
    {Console, Output} = nh_console:handle_input(Data, maps:get(console, State)),
    console_out(Output, State#{console => Console});
handle_event({message, <<"console">>, <<"restart">>, _Payload}, State) ->
    {Console, Output} = nh_console:restart(maps:get(console, State)),
    console_out(Output, State#{console => Console});
%% Sent whenever the operator resizes their terminal. Nothing here wraps text,
%% so there is nothing to do with it — but it must not read as unhandled.
handle_event({message, <<"console">>, <<"window_size">>, _Payload}, State) ->
    State;
%% `file-data/*' pushes a file at a device with a filesystem to put it in. This
%% one has partitions, and silently accepting bytes nothing will ever write
%% would be worse than saying so.
handle_event({message, <<"console">>, <<"file-data/start">>, _Payload}, State) ->
    console_out(
        <<"\r\nfile transfer is not supported on this device\r\n", (nh_console:prompt())/binary>>,
        State
    );
handle_event({message, <<"console">>, <<"file-data">>, _Payload}, State) ->
    State;
handle_event({message, <<"console">>, <<"file-data/stop">>, _Payload}, State) ->
    State;
%% An operator asked for this one explicitly, so it is not deferred to the
%% application the way an armed update is.
%% NervesHub answers a join that asked for them. Added to the configured keys
%% rather than replacing them: a key that arrived over the socket is only as
%% trustworthy as the server that sent it, so it can widen what a device
%% accepts but must never be the reason it accepts something.
handle_event({message, _Topic, <<"fwup_public_keys">>, Payload}, State) ->
    Received = decode_keys(maps:get(<<"keys">>, Payload, [])),
    Keys = lists:usort(maps:get(firmware_keys, State, []) ++ Received),

    notify(State, {firmware_keys, length(Keys)}),
    State#{firmware_keys => stash_keys(Keys)};
handle_event({message, _Topic, <<"reboot">>, _Payload}, State) ->
    notify(State, reboot_requested),
    State1 = push_event(<<"rebooting">>, #{}, State),

    case maps:get(reboot, State1, auto) of
        auto -> reboot(State1);
        _Manual -> State1
    end;
%% Only the application knows what identifying looks like on its hardware --
%% an LED, a buzzer, a line on a display -- so this is reported, not acted on.
handle_event({message, _Topic, <<"identify">>, _Payload}, State) ->
    notify(State, identify),
    State;
handle_event({message, _Topic, <<"update">>, Payload}, State) ->
    notify(State, {message, <<"update">>, Payload}),
    maybe_start_update(Payload, State);
handle_event({message, _Topic, Event, Payload}, State) ->
    notify(State, {message, Event, Payload}),
    State;
handle_event(Other, State) ->
    notify(State, Other),
    State.

%% A device that has just taken an update is on trial until it gets here.
%% Joining is the evidence this library accepts: firmware that cannot reach
%% NervesHub is firmware nothing could recover from remotely, so it is exactly
%% what must not be committed.
validate_pending(State) ->
    case nh_ota:pending() of
        none ->
            State;
        {ok, Slot} ->
            case nh_ota:commit() of
                ok ->
                    notify(State, {firmware_committed, Slot}),
                    push_event(<<"firmware_validated">>, #{}, State);
                {error, Reason} ->
                    notify(State, {firmware_commit_failed, Reason}),
                    State
            end
    end.

maybe_start_update(Payload, State) ->
    Available = maps:get(<<"update_available">>, Payload, false),

    case {maps:get(updates, State, auto), Available, maps:is_key(update, State)} of
        {auto, true, false} ->
            Pid = nh_ota:start_update(Payload, self(), #{
                keys => maps:get(firmware_keys, State, [])
            }),
            notify(State, {update_started, Pid}),
            State#{update => Pid};
        {auto, true, true} ->
            %% One at a time. A second `update' while a download is in flight is
            %% the server repeating itself, not a new job.
            State;
        _ ->
            State
    end.

%% A downloader that exits normally has already sent its result. One that dies
%% any other way has not, and nothing else would ever say so.
updater_down(Pid, Reason, State) when Reason =/= normal ->
    case maps:get(update, State, undefined) of
        Pid ->
            notify(State, {update_failed, {updater_crashed, Reason}}),

            State1 = push_event(
                <<"status_update">>,
                #{<<"status">> => <<"failed">>, <<"reason">> => <<"updater_crashed">>},
                State
            ),
            maps:remove(update, State1);
        _Other ->
            State
    end;
updater_down(_Pid, _Reason, State) ->
    State.

%% Console output only goes anywhere if the channel joined, and `push/4'
%% already refuses on a topic that has not.
console_out(<<>>, State) ->
    State;
console_out(Output, State) ->
    {Channel, Actions} = nh_channel:push(
        <<"console">>, <<"up">>, #{<<"data">> => Output}, maps:get(channel, State)
    ),
    run(Actions, State#{channel => Channel}).

%% `rebooting' has to reach NervesHub before the device goes. A send returns
%% once the frame is handed to the socket, not once it leaves, and `esp:restart/0'
%% is immediate -- so without a pause the platform never learns why the device
%% vanished. The same gap swallowed the update messages on the ESP-IDF agent.
reboot(State) ->
    _ = timer:sleep(?REBOOT_GRACE_MS),
    _ =
        try
            apply(esp, restart, [])
        catch
            _:_ -> ok
        end,
    State.

run_extension_actions(Actions, State) ->
    lists:foldl(fun run_extension_action/2, State, Actions).

run_extension_action({push, Event, Payload}, State) ->
    push_extension(Event, Payload, State);
run_extension_action({resolve_location}, State) ->
    _ = nh_ext_geo:start_resolve(self()),
    State;
run_extension_action(Other, State) ->
    notify(State, Other),
    State.

push_extension(Event, Payload, State) ->
    {Channel, Actions} = nh_channel:push(
        <<"extensions">>, Event, Payload, maps:get(channel, State)
    ),
    run(Actions, State#{channel => Channel}).

maybe_add_extensions(Channel, Extensions) ->
    case nh_extensions:enabled(Extensions) of
        [] ->
            Channel;
        _Some ->
            nh_channel:add_topic(<<"extensions">>, nh_extensions:available(Extensions), Channel)
    end.

%% An organization's keys are not all Ed25519 -- a Secure Boot v2 RSA key is a
%% PEM -- so anything that is not a 32 byte Ed25519 public key is passed over
%% rather than treated as an error.
decode_keys(Keys) when is_list(Keys) ->
    lists:foldr(
        fun(Key, Acc) ->
            case nh_signature:public_key(Key) of
                {ok, Decoded} -> [Decoded | Acc];
                {error, _} -> Acc
            end
        end,
        [],
        Keys
    );
decode_keys(_Other) ->
    [].

%% Asking is opt-in. A device that verifies against keys it was built with does
%% not need them, and asking would only widen what it accepts.
maybe_request_keys(Params, Config) ->
    case maps:get(request_firmware_keys, Config, false) of
        true -> Params#{<<"fwup_public_keys">> => <<"on_connect">>};
        _ -> Params
    end.

%% The console reports on the same keys the updater uses, and it runs on this
%% process, so they are put where it can reach them.
stash_keys(Keys) ->
    _ = erlang:put(nh_firmware_keys, Keys),
    Keys.

maybe_add_console(Channel, Config) ->
    case maps:get(console, Config, false) of
        true -> nh_channel:add_topic(<<"console">>, #{}, Channel);
        _ -> Channel
    end.

push_event(Event, Payload, State) ->
    {Channel, Actions} = nh_channel:push(Event, Payload, maps:get(channel, State)),
    run(Actions, State#{channel => Channel}).

%% NervesHub wants a string for the failure reason, and an Erlang term is not
%% one. Kept crude on purpose: the detail that matters is in the device log.
describe(Reason) when is_binary(Reason) -> Reason;
describe(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
describe(Reason) when is_tuple(Reason), tuple_size(Reason) > 0 -> describe(element(1, Reason));
describe(_Reason) -> <<"update_failed">>.

notify(State, Message) ->
    maps:get(owner, State) ! {nerves_hub, Message},
    ok.

schedule_heartbeat(#{heartbeat_ms := Ms} = State) ->
    State#{heartbeat_at => now_ms() + Ms}.

timeout_until(infinity) ->
    infinity;
timeout_until(At) ->
    case At - now_ms() of
        Remaining when Remaining > 0 -> Remaining;
        _ -> 0
    end.

now_ms() ->
    erlang:system_time(millisecond).

join_params(Config) ->
    case maps:get(metadata, Config, undefined) of
        undefined -> #{};
        Metadata -> nh_metadata:join_params(Metadata)
    end.

transport_config(Config, Url) ->
    Base = #{
        url => Url,
        owner => self(),
        verify => maps:get(verify, Config, crt_bundle)
    },

    WithAuth =
        case maps:get(shared_secret, Config, undefined) of
            {Key, Secret} ->
                Identifier = maps:get(identifier, Config),
                Base#{headers => nh_shared_secret:headers(Identifier, Key, Secret)};
            undefined ->
                Base
        end,

    case maps:get(client_cert, Config, undefined) of
        undefined -> WithAuth;
        CertAndKey -> WithAuth#{client_cert => CertAndKey}
    end.
