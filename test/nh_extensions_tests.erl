%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_extensions_tests).

-include_lib("eunit/include/eunit.hrl").

all_enabled() -> nh_extensions:new(#{extensions => all}).

attached_all() ->
    {State, _Actions} = nh_extensions:attach(
        [<<"health">>, <<"geo">>, <<"logging">>], all_enabled()
    ),
    State.

%% Each extension costs traffic a device may not want to spend.
nothing_is_enabled_by_default_test() ->
    State = nh_extensions:new(#{}),
    ?assertEqual([], nh_extensions:enabled(State)),
    ?assertEqual(#{}, nh_extensions:available(State)).

enabled_by_name_test() ->
    State = nh_extensions:new(#{extensions => [health, logging]}),
    ?assertEqual([<<"health">>, <<"logging">>], nh_extensions:enabled(State)).

logs_is_accepted_as_an_alias_test() ->
    ?assertEqual(
        [<<"logging">>], nh_extensions:enabled(nh_extensions:new(#{extensions => [logs]}))
    ).

unknown_extensions_are_dropped_test() ->
    ?assertEqual(
        [<<"health">>], nh_extensions:enabled(nh_extensions:new(#{extensions => [health, wat]}))
    ).

available_declares_a_version_per_extension_test() ->
    Available = nh_extensions:available(all_enabled()),
    ?assertEqual([<<"geo">>, <<"health">>, <<"logging">>], lists:sort(maps:keys(Available))),
    lists:foreach(fun(V) -> ?assertEqual(<<"0.0.1">>, V) end, maps:values(Available)).

%% The platform decides what is on; a product may have an extension switched off.
attach_uses_the_join_reply_test() ->
    {State, _} = nh_extensions:attach([<<"health">>], all_enabled()),
    ?assertEqual([<<"health">>], nh_extensions:attached(State)),
    ?assert(nh_extensions:is_attached(<<"health">>, State)),
    ?assertNot(nh_extensions:is_attached(<<"geo">>, State)).

%% Being told to attach something this device never offered is not a reason to
%% start answering for it.
attach_ignores_what_was_never_offered_test() ->
    {State, _Actions} = nh_extensions:attach(
        [<<"health">>, <<"local_shell">>], nh_extensions:new(#{extensions => [health]})
    ),
    ?assertEqual([<<"health">>], nh_extensions:attached(State)).

attach_handles_a_reply_that_is_not_a_list_test() ->
    {State, Actions} = nh_extensions:attach(#{}, all_enabled()),
    ?assertEqual([], nh_extensions:attached(State)),
    ?assertEqual([], Actions).

%% The event name after the extension may contain colons of its own.
scope_splits_on_the_first_colon_test() ->
    ?assertEqual({<<"health">>, <<"check">>}, nh_extensions:scope(<<"health:check">>)),
    ?assertEqual(
        {<<"geo">>, <<"location:request">>}, nh_extensions:scope(<<"geo:location:request">>)
    ),
    ?assertEqual(error, nh_extensions:scope(<<"nocolon">>)),
    ?assertEqual(error, nh_extensions:scope(<<":leading">>)),
    ?assertEqual(error, nh_extensions:scope(<<"trailing:">>)).

health_check_answers_with_a_report_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"health:check">>, #{}, attached_all()),

    ?assertMatch([{push, <<"health:report">>, #{<<"value">> := _}}], Actions),
    [{push, _, #{<<"value">> := Report}}] = Actions,
    ?assert(maps:is_key(<<"metrics">>, Report)).

%% Resolving means an HTTP request, so it comes back as work for the caller.
geo_request_defers_the_network_call_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"geo:location:request">>, #{}, attached_all()),
    ?assertEqual([{resolve_location}], Actions).

%% Answering for something the platform never turned on would be answering a
%% question it did not ask.
an_event_for_a_detached_extension_is_dropped_test() ->
    {State, _} = nh_extensions:attach([<<"health">>], all_enabled()),
    {_State, Actions} = nh_extensions:handle_event(<<"geo:location:request">>, #{}, State),
    ?assertMatch([{not_attached, <<"geo">>, _}], Actions).

an_unscoped_event_is_reported_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"nonsense">>, #{}, attached_all()),
    ?assertMatch([{unknown_extension_event, <<"nonsense">>}], Actions).

an_unknown_event_within_an_extension_is_reported_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"health:wat">>, #{}, attached_all()),
    ?assertMatch([{unhandled_extension_event, <<"health">>, <<"wat">>}], Actions).

%% NervesHub waits for this before it starts an extension. Without it the
%% device is attached and never spoken to again, and nothing looks wrong.
attach_confirms_each_extension_test() ->
    {_State, Actions} = nh_extensions:attach([<<"health">>, <<"geo">>], all_enabled()),

    ?assertEqual(
        [
            {push, <<"health:attached">>, #{}},
            {push, <<"geo:attached">>, #{}}
        ],
        Actions
    ).

nothing_is_confirmed_that_was_not_attached_test() ->
    {_State, Actions} = nh_extensions:attach([<<"local_shell">>], all_enabled()),
    ?assertEqual([], Actions).
