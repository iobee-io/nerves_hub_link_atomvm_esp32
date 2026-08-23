%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The extensions channel: health, geo and logs.
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
-export([handle_event/3, scope/1]).

-define(GEO, <<"geo">>).
-define(HEALTH, <<"health">>).
-define(LOGGING, <<"logging">>).

%% The versions NervesHub's own client speaks. Claiming a version is claiming a
%% wire format, so these track `nerves_hub_link' rather than this library.
-define(VERSION, <<"0.0.1">>).

-type state() :: #{enabled := [binary()], attached := [binary()]}.

-export_type([state/0]).

%%-----------------------------------------------------------------------------
%% @doc Build the registry from configuration.
%%
%% `extensions => [health, geo, logging]', or `all'. Nothing is enabled by
%% default: each one costs traffic a device may not want to spend.
%% @end
%%-----------------------------------------------------------------------------
-spec new(map()) -> state().
new(Config) ->
    Enabled =
        case maps:get(extensions, Config, []) of
            all -> [?HEALTH, ?GEO, ?LOGGING];
            List when is_list(List) -> [normalise(E) || E <- List];
            _ -> []
        end,

    #{enabled => [E || E <- Enabled, E =/= undefined], attached => []}.

normalise(health) -> ?HEALTH;
normalise(geo) -> ?GEO;
normalise(logging) -> ?LOGGING;
normalise(logs) -> ?LOGGING;
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
    maps:from_list([{Name, ?VERSION} || Name <- Enabled]).

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
    {State, [{push, <<"health:report">>, #{<<"value">> => nh_ext_health:report()}}]};
dispatch(?GEO, <<"location:request">>, _Payload, State) ->
    %% Resolving means an HTTP request, which does not belong on the process
    %% that has heartbeats to send.
    {State, [{resolve_location}]};
dispatch(Name, Event, _Payload, State) ->
    {State, [{unhandled_extension_event, Name, Event}]}.
