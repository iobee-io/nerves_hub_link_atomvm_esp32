%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The extensions channel: health, geo, logs and alarms.
%%
%% Extensions are optional capabilities a device offers and the platform turns
%% on. The device joins the `extensions' topic with what it can do and the
%% versions it speaks, and the join reply names the subset the platform wants
%% attached — a device may support an extension the product has switched off.
%%
%% ```
%% join payload   #{<<"health">> => <<"0.0.1">>, ...}   device -> server
%% join reply     [<<"health">>, <<"geo">>]             server -> device
%% '''
%%
%% == Scoped events ==
%%
%% Every event on this topic is prefixed with the extension it belongs to, so
%% `health:check' is `check' for `health'. Splitting on the first colon is the
%% whole of the routing — the rest of the event name may contain colons of its
%% own, as `geo:location:request' does.
%%
%% == What this module does not do ==
%%
%% It has no side effects. Building a health report reads the system, resolving
%% a location makes an HTTP request, and neither belongs in a routing table, so
%% both come back as actions for the caller to carry out. See `nh_agent'.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_extensions).

-export([new/1, available/1, enabled/1, attach/2, attached/1, is_attached/2]).
-export([handle_event/3, scope/1, polls_alarms/1, poll_alarms/1]).

-define(ALARMS, <<"alarms">>).
-define(GEO, <<"geo">>).
-define(HEALTH, <<"health">>).
-define(LOGGING, <<"logging">>).

%% The versions NervesHub's own client speaks. Claiming a version is claiming a
%% wire format, so these track `nerves_hub_link' rather than this library.
-define(VERSION, <<"0.0.1">>).
%% `alarms' arrived after the others, at its own version.
-define(ALARMS_VERSION, <<"0.1.0">>).

-type state() :: #{
    enabled := [binary()],
    attached := [binary()],
    %% Whatever the application returns: checked on each report.
    alarms := undefined | fun(() -> term()) | fun((map()) -> term()),
    %% What the application last said was raised, and since when.
    raised := nh_ext_alarms:raised()
}.

-export_type([state/0]).

%%-----------------------------------------------------------------------------
%% @doc Build the registry from configuration.
%%
%% `extensions => [health, geo, logging, alarms]', or `all'. Nothing is
%% enabled by default: each one costs traffic a device may not want to spend.
%%
%% `alarms => Fun' gives the application's alarms: it returns the complete set
%% raised right now, `#{Name => Description}'. It is called for each health
%% report and, with the `alarms' extension, every `alarms_interval_ms' (see
%% `nh_agent'). A `Fun' of one argument is given what it returned last time,
%% so an alarm can be cleared at a different level from the one that raised it
%% without the application keeping state of its own.
%% @end
%%-----------------------------------------------------------------------------
-spec new(map()) -> state().
new(Config) ->
    Enabled =
        case maps:get(extensions, Config, []) of
            all -> [?HEALTH, ?GEO, ?LOGGING, ?ALARMS];
            List when is_list(List) -> [normalise(E) || E <- List];
            _ -> []
        end,

    #{
        enabled => [E || E <- Enabled, E =/= undefined],
        attached => [],
        alarms => maps:get(alarms, Config, undefined),
        raised => nh_ext_alarms:new()
    }.

normalise(health) -> ?HEALTH;
normalise(geo) -> ?GEO;
normalise(logging) -> ?LOGGING;
normalise(logs) -> ?LOGGING;
normalise(alarms) -> ?ALARMS;
normalise(?ALARMS) -> ?ALARMS;
normalise(?HEALTH) -> ?HEALTH;
normalise(?GEO) -> ?GEO;
normalise(?LOGGING) -> ?LOGGING;
normalise(_Other) -> undefined.

%%-----------------------------------------------------------------------------
%% @doc The join payload: what this device offers, and at which version.
%% @end
%%-----------------------------------------------------------------------------
-spec available(state()) -> map().
available(#{enabled := Enabled}) ->
    maps:from_list([{Name, version(Name)} || Name <- Enabled]).

version(?ALARMS) -> ?ALARMS_VERSION;
version(_Name) -> ?VERSION.

-spec enabled(state()) -> [binary()].
enabled(#{enabled := Enabled}) -> Enabled.

%%-----------------------------------------------------------------------------
%% @doc Record the attach list from the join reply, and confirm it.
%%
%% Anything the platform did not name stays detached, and anything named that
%% this device does not actually offer is ignored rather than trusted.
%%
%% The confirmations are the point. NervesHub does not start an extension when
%% it puts it in the attach list — it waits for the device to answer
%% `&lt;key&gt;:attached', and only then runs the extension's own attach, which
%% is what asks for the first health report and the first location. A device
%% that attaches silently is a device the platform never speaks to again, and
%% nothing about that looks like an error from either end.
%% @end
%%-----------------------------------------------------------------------------
-spec attach(term(), state()) -> {state(), [term()]}.
attach(Response, #{enabled := Enabled} = State) when is_list(Response) ->
    Attached = [Name || Name <- Response, lists:member(Name, Enabled)],
    {State#{attached => Attached}, [{push, <<Name/binary, ":attached">>, #{}} || Name <- Attached]};
attach(_Response, State) ->
    {State#{attached => []}, []}.

-spec attached(state()) -> [binary()].
attached(#{attached := Attached}) -> Attached.

-spec is_attached(binary(), state()) -> boolean().
is_attached(Name, #{attached := Attached}) -> lists:member(Name, Attached).

%%-----------------------------------------------------------------------------
%% @doc Split a scoped event into its extension and the event within it.
%% @end
%%-----------------------------------------------------------------------------
-spec scope(binary()) -> {binary(), binary()} | error.
scope(Scoped) ->
    case binary:split(Scoped, <<":">>) of
        [Name, Event] when Name =/= <<>>, Event =/= <<>> -> {Name, Event};
        _ -> error
    end.

%%-----------------------------------------------------------------------------
%% @doc Route an event to its extension.
%%
%% Returns actions rather than performing them: `{push, ScopedEvent, Payload}'
%% to answer immediately, `{resolve_location}' for the one that needs the
%% network. An event for an extension that is not attached is dropped — the
%% platform asking for something it never turned on is not something to answer.
%% @end
%%-----------------------------------------------------------------------------
-spec handle_event(binary(), map(), state()) -> {state(), [term()]}.
handle_event(Scoped, Payload, State) ->
    case scope(Scoped) of
        error ->
            {State, [{unknown_extension_event, Scoped}]};
        {Name, Event} ->
            case is_attached(Name, State) of
                false -> {State, [{not_attached, Name, Event}]};
                true -> dispatch(Name, Event, Payload, State)
            end
    end.

dispatch(?HEALTH, <<"check">>, _Payload, State) ->
    {State1, Events} = poll_alarms(State),
    %% With `alarms' attached the report says nothing about alarms: an absent
    %% key leaves alone what the events stored, and `#{}' would clear it.
    Alarms =
        case is_attached(?ALARMS, State1) of
            true -> undefined;
            false -> nh_ext_alarms:current(maps:get(raised, State1))
        end,
    Report = nh_ext_health:report(Alarms),
    {State1, Events ++ [{push, <<"health:report">>, #{<<"value">> => Report}}]};
dispatch(?ALARMS, <<"sync">>, _Payload, State) ->
    %% The snapshot says everything the events would, so they are not sent too:
    %% each one costs a token of NervesHub's rate limit.
    {State1, _Events} = poll_alarms(State),
    {State1, [{push, <<"alarms:snapshot">>, nh_ext_alarms:snapshot(maps:get(raised, State1))}]};
dispatch(?GEO, <<"location:request">>, _Payload, State) ->
    %% Resolving means an HTTP request, which does not belong on the process
    %% that has heartbeats to send.
    {State, [{resolve_location}]};
dispatch(Name, Event, _Payload, State) ->
    {State, [{unhandled_extension_event, Name, Event}]}.

%%-----------------------------------------------------------------------------
%% @doc Whether the agent should ask the application for its alarms on a timer.
%% @end
%%-----------------------------------------------------------------------------
-spec polls_alarms(state()) -> boolean().
polls_alarms(#{enabled := Enabled, alarms := Fun}) ->
    lists:member(?ALARMS, Enabled) andalso
        (is_function(Fun, 0) orelse is_function(Fun, 1)).

%%-----------------------------------------------------------------------------
%% @doc Ask the application for its alarms, and push what changed.
%%
%% The set is followed even while `alarms' is not attached, so that an alarm
%% raised while the device was offline keeps the time it was raised; only the
%% pushes wait for the extension.
%% @end
%%-----------------------------------------------------------------------------
-spec poll_alarms(state()) -> {state(), [term()]}.
poll_alarms(#{raised := Raised} = State) ->
    case alarms(State) of
        error ->
            {State, []};
        Current ->
            {Raised1, Events} = nh_ext_alarms:update(Current, Raised, nh_ext_health:timestamp()),
            Pushes =
                case is_attached(?ALARMS, State) of
                    true -> [{push, Event, Payload} || {Event, Payload} <- Events];
                    false -> []
                end,
            {State#{raised => Raised1}, Pushes}
    end.

%% A report is what you ask for when something is wrong, so an application
%% callback that fails costs nothing: what was raised stays raised.
alarms(#{alarms := Fun}) when is_function(Fun, 0) ->
    checked(fun() -> Fun() end);
alarms(#{alarms := Fun, raised := Raised}) when is_function(Fun, 1) ->
    checked(fun() -> Fun(nh_ext_alarms:current(Raised)) end);
alarms(_State) ->
    #{}.

checked(Call) ->
    try Call() of
        Alarms when is_map(Alarms) -> Alarms;
        _Other -> error
    catch
        _:_ -> error
    end.
