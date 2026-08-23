%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_console_h_tests).

-include_lib("eunit/include/eunit.hrl").

%% Microseconds, which is what `logger' hands a handler. 2026-08-23.
-define(WHEN, 1787443200000000).

event(Msg) -> event(Msg, #{}).

event(Msg, Meta) ->
    #{level => info, msg => Msg, pid => self(), timestamp => ?WHEN, meta => Meta}.

%% There is no `console' module off a device, so what is being tested is that
%% the line is built without raising -- a handler that crashes takes the
%% process that logged with it.
every_message_shape_is_handled_test() ->
    ?assertEqual(ok, nh_console_h:log(event({string, "plain"}), #{})),
    ?assertEqual(ok, nh_console_h:log(event({"~s is ~p", ["answer", 42]}), #{})),
    ?assertEqual(ok, nh_console_h:log(event({report, #{a => 1}}), #{})),
    ?assertEqual(ok, nh_console_h:log(event({<<"from elixir">>, []}), #{})).

a_location_is_handled_whether_or_not_it_is_there_test() ->
    Meta = #{location => #{mfa => {some_module, some_function, 2}}},

    ?assertEqual(ok, nh_console_h:log(event({string, "located"}, Meta), #{})),
    ?assertEqual(ok, nh_console_h:log(event({string, "not located"}, #{}), #{})).

%% Every level `logger' has, since an unhandled one would crash the caller.
every_level_is_handled_test() ->
    Levels = [emergency, alert, critical, error, warning, notice, info, debug],

    [
        ?assertEqual(ok, nh_console_h:log((event({string, "x"}))#{level => Level}, #{}))
     || Level <- Levels
    ].

the_handler_entry_carries_a_level_test() ->
    %% `logger' reads `level' out of a handler's config on every call and
    %% crashes on a config without one.
    {handler, _Id, nh_console_h, Config} = nh_console_h:handler(),
    ?assertEqual(info, maps:get(level, Config)),

    {handler, _Id2, nh_console_h, Configured} = nh_console_h:handler(#{level => debug}),
    ?assertEqual(debug, maps:get(level, Configured)).

%% `logger_manager' adds `logger_std_h' under `default' unless something else
%% claims it, and this replaces `logger_std_h'. Under any other id both run and
%% every line is printed twice.
the_handler_claims_the_default_id_test() ->
    ?assertMatch({handler, default, nh_console_h, _}, nh_console_h:handler()),
    ?assertMatch({handler, default, nh_console_h, _}, nh_console_h:handler(#{level => debug})).
