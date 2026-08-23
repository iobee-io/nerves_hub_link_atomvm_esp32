%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_io_capture_tests).

-include_lib("eunit/include/eunit.hrl").

%% The capture process will not forward what the agent itself printed, so the
%% printing has to happen somewhere other than the test process -- which is
%% standing in for the agent.
printed(Fun) -> printed(Fun, #{}).

printed(Fun, Opts) ->
    {ok, Capture} = start(Opts),

    Printer = spawn(fun() ->
        receive
            go -> Fun()
        end
    end),

    %% Attached before it prints anything, or the first line goes to whatever
    %% group leader it was born with.
    ok = nh_io_capture:attach(Capture, Printer),
    Printer ! go,

    collect([]).

start(Opts) ->
    nh_io_capture:start(maps:merge(#{echo => false}, Opts#{agent => self()})).

collect(Acc) ->
    receive
        {push_extension, Event, Line} ->
            collect([{Event, maps:get(<<"message">>, Line)} | Acc])
    after 300 ->
        lists:reverse(Acc)
    end.

messages(Sent) -> [Message || {_Event, Message} <- Sent].

what_a_process_prints_arrives_at_the_agent_test() ->
    Sent = printed(fun() -> io:format("hello from the device~n") end),

    ?assertEqual([{nh_ext_logs:event(), <<"hello from the device">>}], Sent).

%% The whole point: code that reports with `io:format' rather than `logger',
%% which on AtomVM is most of it.
formatting_and_arguments_survive_test() ->
    Sent = printed(fun() -> io:format("~s is ~p~n", ["answer", 42]) end),

    ?assertEqual([<<"answer is 42">>], messages(Sent)).

%% One `io:format' can print several lines, and they should not arrive as one.
a_write_is_split_on_newlines_test() ->
    Sent = printed(fun() -> io:format("one~ntwo~nthree~n") end),

    ?assertEqual([<<"one">>, <<"two">>, <<"three">>], messages(Sent)).

%% Sent rather than held: a buffer waiting for a newline that never comes is a
%% log line lost to whatever happens next.
a_write_without_a_newline_is_still_sent_test() ->
    Sent = printed(fun() -> io:put_chars("no newline here") end),

    ?assertEqual([<<"no newline here">>], messages(Sent)).

%% Group leaders are inherited, which is what makes this worth doing at all --
%% one call covers the processes the application starts later.
processes_spawned_afterwards_are_captured_too_test() ->
    Sent = printed(fun() ->
        Child = spawn(fun() -> io:format("from a child~n") end),
        Ref = monitor(process, Child),
        receive
            {'DOWN', Ref, process, Child, _} -> ok
        after 500 -> ok
        end
    end),

    ?assertEqual([<<"from a child">>], messages(Sent)).

%% `io:execute_request/2' waits for a reply with no timeout, so a request that
%% goes unanswered blocks the printing process for good. Nothing below is about
%% log lines; every one of them is about not hanging a device.
a_request_it_does_not_understand_is_still_answered_test() ->
    ?assertEqual({error, request}, request({some_later_addition_to_the_protocol, x})).

a_request_that_crashes_is_still_answered_test() ->
    %% `apply' raises, so the reply can only come from the handler's own catch.
    ?assertEqual({error, request}, request({put_chars, unicode, erlang, error, [boom]})).

reading_is_answered_with_eof_rather_than_waited_on_test() ->
    ?assertEqual(eof, request({get_line, unicode, "> "})),
    ?assertEqual(eof, request({get_chars, unicode, "> ", 10})),
    ?assertEqual(eof, request({get_until, unicode, "> ", io_lib, fread, ["~d"]})).

%% `io:format' with no arguments arrives as this on some paths, and a batched
%% write arrives as a list of requests.
every_writing_shape_is_answered_test() ->
    ?assertEqual(ok, request({put_chars, "bare"})),
    ?assertEqual(ok, request({put_chars, unicode, "encoded"})),
    ?assertEqual(ok, request({put_chars, unicode, io_lib, format, ["~s", ["applied"]]})),
    ?assertEqual(ok, request({requests, [{put_chars, unicode, "a"}, {put_chars, unicode, "b"}]})),
    ?assertEqual(ok, request({setopts, [{encoding, unicode}]})).

request(Request) ->
    {ok, Capture} = nh_io_capture:start(#{echo => false, agent => undefined}),
    Ref = make_ref(),
    Capture ! {io_request, self(), Ref, Request},

    receive
        {io_reply, Ref, Reply} -> Reply
    after 500 -> never_answered
    end.

%% Otherwise the agent's own printing is something to send, and sending it
%% prints.
the_agent_is_not_asked_to_report_its_own_printing_test() ->
    {ok, Capture} = nh_io_capture:start(#{echo => false, agent => self()}),
    Ref = make_ref(),
    Capture ! {io_request, self(), Ref, {put_chars, unicode, "agent chatter\n"}},

    receive
        {io_reply, Ref, ok} -> ok
    after 500 -> ?assert(false)
    end,

    ?assertEqual([], collect([])).

%% A batch is several writes, not one.
a_batch_reports_each_write_test() ->
    Sent = printed(fun() ->
        Capture = group_leader(),
        Ref = make_ref(),
        Capture !
            {io_request, self(), Ref,
                {requests, [{put_chars, unicode, "a\n"}, {put_chars, unicode, "b\n"}]}},
        receive
            {io_reply, Ref, _} -> ok
        after 500 -> ok
        end
    end),

    ?assertEqual([<<"a">>, <<"b">>], messages(Sent)).

%% A process that is its own group leader is AtomVM's "no group leader", which
%% is what sends printing back to the console. Asserted rather than printed:
%% doing it for real needs `console:print/1', which is on the device.
detaching_puts_a_process_back_on_its_own_test() ->
    {ok, Capture} = start(#{}),

    Printer = spawn(fun() ->
        receive
            {leader, To} -> To ! {leader, group_leader()}
        end,
        receive
            {leader, To2} -> To2 ! {leader, group_leader()}
        end
    end),

    ok = nh_io_capture:attach(Capture, Printer),
    ?assertEqual(Capture, leader_of(Printer)),

    ok = nh_io_capture:detach(Printer),
    ?assertEqual(Printer, leader_of(Printer)).

leader_of(Pid) ->
    Pid ! {leader, self()},
    receive
        {leader, Leader} -> Leader
    after 500 -> never_answered
    end.

stopping_ends_the_capture_process_test() ->
    {ok, Capture} = nh_io_capture:start(#{echo => false}),
    Ref = monitor(process, Capture),

    ok = nh_io_capture:stop(Capture),

    receive
        {'DOWN', Ref, process, Capture, _Reason} -> ok
    after 500 -> ?assert(false)
    end.
