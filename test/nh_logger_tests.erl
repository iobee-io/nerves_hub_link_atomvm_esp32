%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_logger_tests).

-include_lib("eunit/include/eunit.hrl").

%% Microseconds, which is what `logger' hands a handler and what NervesHub
%% wants. 2026-08-23.
-define(WHEN, 1787443200000000).

event(Msg) -> event(Msg, #{}).

event(Msg, Meta) ->
    #{level => info, msg => Msg, pid => self(), timestamp => ?WHEN, meta => Meta}.

%% A stand-in agent, in its own process: the handler deliberately refuses to
%% send to the process it is called from, so the test cannot be the agent.
sent(Event) -> sent(Event, #{}).

sent(Event, Config) ->
    Test = self(),
    Agent = spawn(fun() ->
        receive
            Message -> Test ! Message
        end
    end),

    ok = nh_logger:log(Event, Config#{agent => Agent}),

    receive
        {push_extension, Event0, Line} -> {Event0, Line}
    after 500 -> nothing_sent
    end.

a_line_goes_out_on_the_logging_event_test() ->
    {Event, Line} = sent(event({string, "hello"})),

    ?assertEqual(nh_ext_logs:event(), Event),
    ?assertEqual(<<"hello">>, maps:get(<<"message">>, Line)),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Line)).

%% `logger' hands over one of three shapes, and losing one loses whichever
%% messages happen to use it.
every_message_shape_is_rendered_test() ->
    {_, String} = sent(event({string, "plain"})),
    ?assertEqual(<<"plain">>, maps:get(<<"message">>, String)),

    {_, Format} = sent(event({"~s is ~p", ["answer", 42]})),
    ?assertEqual(<<"answer is 42">>, maps:get(<<"message">>, Format)),

    {_, Report} = sent(event({report, #{a => 1}})),
    ?assert(byte_size(maps:get(<<"message">>, Report)) > 0).

%% Elixir has no `Logger' on AtomVM, so Elixir code calls `:logger.info("...")'
%% with a binary. AtomVM turns that into a format string with no arguments, and
%% rendering it as a term would make every Elixir log line `{<<"...">>,[]}'.
an_elixir_binary_message_is_rendered_test() ->
    {_, Line} = sent(event({<<"from elixir">>, []})),
    ?assertEqual(<<"from elixir">>, maps:get(<<"message">>, Line)),

    {_, Formatted} = sent(event({<<"~s and ~p">>, ["this", 2]})),
    ?assertEqual(<<"this and 2">>, maps:get(<<"message">>, Formatted)).

%% A mismatched format and arguments would otherwise take down whichever
%% process was logging.
a_broken_format_does_not_crash_the_caller_test() ->
    {_, Line} = sent(event({"~s ~s ~s", ["only one"]})),
    ?assert(byte_size(maps:get(<<"message">>, Line)) > 0).

%% Stamped when it happened, not when it was sent.
the_events_own_timestamp_is_used_test() ->
    {_, Line} = sent(event({string, "hi"})),
    ?assertEqual(integer_to_binary(?WHEN), maps:get(<<"time">>, maps:get(<<"meta">>, Line))).

%% A clock that was never set has no honest timestamp, and NervesHub drops a
%% line without one anyway.
an_unset_clock_sends_nothing_test() ->
    ?assertEqual(nothing_sent, sent((event({string, "hi"}))#{timestamp => 0})).

useful_metadata_is_carried_test() ->
    {_, Line} = sent(event({string, "hi"}, #{module => nh_agent, line => 42, secret => <<"x">>})),
    Meta = maps:get(<<"meta">>, Line),

    ?assertEqual(<<"nh_agent">>, maps:get(<<"module">>, Meta)),
    ?assertEqual(<<"42">>, maps:get(<<"line">>, Meta)),
    %% and nothing else, because a logger's metadata can carry anything
    ?assertNot(maps:is_key(<<"secret">>, Meta)).

%% The handler is configured before the agent exists, and outlives it.
no_agent_is_not_an_error_test() ->
    ?assertEqual(ok, nh_logger:log(event({string, "hi"}), #{agent => nothing_registered_here})),
    ?assertEqual(ok, nh_logger:log(event({string, "hi"}), #{agent => "not a name"})).

%% The agent logging something would otherwise be asked to send it to itself
%% while it is doing so.
the_agent_does_not_log_to_itself_test() ->
    flush(),

    ?assertEqual(ok, nh_logger:log(event({string, "hi"}), #{agent => self()})),
    ?assertEqual(nothing, next()).

%% How it is actually configured: the handler is set up before the agent exists,
%% so it resolves a name each time rather than holding a pid.
an_agent_is_found_by_registered_name_test() ->
    Test = self(),
    Agent = spawn(fun() ->
        receive
            Message -> Test ! Message
        end
    end),
    Name = list_to_atom("nh_logger_named_" ++ integer_to_list(erlang:unique_integer([positive]))),
    true = register(Name, Agent),

    ok = nh_logger:log(event({string, "by name"}), #{agent => Name}),

    receive
        {push_extension, _Event, Line} ->
            ?assertEqual(<<"by name">>, maps:get(<<"message">>, Line))
    after 500 ->
        ?assert(false)
    end.

handler_returns_a_logger_manager_entry_test() ->
    ?assertMatch({handler, nerves_hub, nh_logger, #{level := info}}, nh_logger:handler()),
    ?assertMatch(
        {handler, nerves_hub, nh_logger, #{level := error}}, nh_logger:handler(#{level => error})
    ).

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

next() ->
    receive
        Message -> Message
    after 200 -> nothing
    end.

%% `logger' reads the level out of a handler's config without a default, so a
%% handler without one takes the logger down on the first message.
handler_always_has_a_level_test() ->
    ?assertMatch({handler, nerves_hub, nh_logger, #{level := info}}, nh_logger:handler(#{})),
    ?assertMatch(
        {handler, nerves_hub, nh_logger, #{level := error, agent := somewhere}},
        nh_logger:handler(#{level => error, agent => somewhere})
    ).
