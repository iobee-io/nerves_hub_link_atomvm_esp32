%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_agent_tests).

-include_lib("eunit/include/eunit.hrl").

%% A transport the test drives by hand: it records what the agent sends and lets
%% the test deliver socket events. Registered under its own name so the module
%% callbacks can reach it without the agent knowing it exists.
-export([open/1, send_text/2, close/1]).

open(Config) ->
    ?MODULE ! {opened, self(), Config},
    {ok, fake_handle}.

send_text(fake_handle, Frame) ->
    ?MODULE ! {sent, Frame},
    ok.

close(fake_handle) ->
    ?MODULE ! closed,
    ok.

setup() ->
    %% eunit runs every test in the same process, and a process may hold only one
    %% registered name — so drop whichever name the previous test module left on
    %% it before claiming this one. Its leftover messages go too, or this test
    %% reads them as its own.
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unregister(Name);
        _ -> ok
    end,
    register(?MODULE, self()),
    flush(),
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

config(Extra) ->
    maps:merge(
        #{
            url => "wss://example.com/socket/websocket",
            identifier => <<"dev-1">>,
            transport => ?MODULE,
            handler => self(),
            metadata => nh_metadata:describe(
                #{name => <<"my_app">>, vsn => <<"1.2.3">>, description => <<"a test app">>},
                binary:copy(<<"ab">>, 32)
            )
        },
        Extra
    ).

%% The agent must not join until the socket says it is up.
joins_only_once_connected_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),

    receive
        {opened, AgentPid, _} -> ?assertEqual(Agent, AgentPid)
    after 1000 -> ?assert(false)
    end,

    ?assertEqual(nothing_sent, next_sent(200)),

    Agent ! {websocket, fake_handle, connected},
    Frame = next_sent(1000),
    [_JoinRef, _Ref, Topic, Event, Payload] = json:decode(Frame),
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(<<"phx_join">>, Event),
    ?assertEqual(<<"my_app">>, maps:get(<<"atomvm_app_name">>, Payload)),

    nh_agent:stop(Agent).

%% The whole reason the agent watches for `connected' rather than joining once:
%% a Phoenix channel does not survive a socket reconnect.
rejoins_on_every_connection_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    First = json:decode(next_sent(1000)),

    Agent ! {websocket, fake_handle, {closed, disconnected}},
    Agent ! {websocket, fake_handle, connected},
    Second = json:decode(next_sent(1000)),

    ?assertEqual(<<"phx_join">>, lists:nth(4, First)),
    ?assertEqual(<<"phx_join">>, lists:nth(4, Second)),
    %% A new join reference, so a late reply to the old join cannot be mistaken
    %% for this one.
    ?assertNotEqual(lists:nth(1, First), lists:nth(1, Second)),

    nh_agent:stop(Agent).

sends_heartbeats_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{heartbeat_ms => 100})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    _Join = next_sent(1000),

    Heartbeat = json:decode(next_sent(1000)),
    ?assertEqual(null, lists:nth(1, Heartbeat)),
    ?assertEqual(<<"phoenix">>, lists:nth(3, Heartbeat)),
    ?assertEqual(<<"heartbeat">>, lists:nth(4, Heartbeat)),

    nh_agent:stop(Agent).

%% Incoming traffic must not starve the heartbeat. With a `receive ... after'
%% timeout it would: every message would reset the clock and the server would
%% eventually close a socket that looks busy.
traffic_does_not_starve_the_heartbeat_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{heartbeat_ms => 300})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    _Join = next_sent(1000),

    %% Chatter at a shorter interval than the heartbeat, for longer than one.
    Noise = json:encode([null, null, <<"device">>, <<"noise">>, #{}]),
    [
        begin
            Agent ! {websocket, fake_handle, {text, iolist_to_binary(Noise)}},
            timer:sleep(50)
        end
     || _ <- lists:seq(1, 10)
    ],

    Frame = json:decode(next_sent(1000)),
    ?assertEqual(<<"heartbeat">>, lists:nth(4, Frame)),

    nh_agent:stop(Agent).

surfaces_join_and_messages_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    Frame = json:decode(next_sent(1000)),
    [JoinRef, Ref | _] = Frame,

    Reply = json:encode([
        JoinRef,
        Ref,
        <<"device">>,
        <<"phx_reply">>,
        #{
            <<"status">> => <<"ok">>, <<"response">> => #{}
        }
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    ?assertMatch({joined, _}, next_event(1000)),

    Update = json:encode([
        JoinRef,
        null,
        <<"device">>,
        <<"update">>,
        #{
            <<"firmware_url">> => <<"https://example.com/fw.bin">>
        }
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Update)}},
    ?assertMatch({message, <<"update">>, #{<<"firmware_url">> := _}}, next_event(1000)),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------------- helpers

next_opened() ->
    receive
        {opened, _, Config} -> Config
    after 1000 -> erlang:error(never_opened)
    end.

next_sent(Timeout) ->
    receive
        {sent, Frame} -> Frame
    after Timeout -> nothing_sent
    end.

next_event(Timeout) ->
    receive
        {nerves_hub, Event} -> Event
    after Timeout -> no_event
    end.

%% Joins and returns {Agent, JoinRef}.
join(Config) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(Config)),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    Reply = json:encode([
        JoinRef,
        Ref,
        <<"device">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => #{}}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    ?assertMatch({joined, _}, next_event(1000)),
    {Agent, JoinRef}.

send_update(Agent, JoinRef, Payload) ->
    Frame = json:encode([JoinRef, null, <<"device">>, <<"update">>, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% The download runs in its own process, and reports back. Off a device it
%% cannot write flash, so it fails immediately — which is the whole path from
%% the server's message to the failure reported back to the server.
an_available_update_is_downloaded_and_failures_reported_test() ->
    {Agent, JoinRef} = join(#{}),

    send_update(Agent, JoinRef, #{
        <<"update_available">> => true,
        <<"firmware_url">> => <<"http://example.com/fw.avm">>,
        <<"size">> => 1024,
        <<"checksum">> => <<"abc">>
    }),

    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertMatch({update_started, _Pid}, next_event(1000)),
    ?assertMatch({update_failed, no_flash_access}, next_event(2000)),

    %% and the failure goes back to NervesHub rather than only to the log
    Reported = wait_for_event(<<"status_update">>, 2000),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Reported)),
    ?assertEqual(<<"no_flash_access">>, maps:get(<<"reason">>, Reported)),

    nh_agent:stop(Agent).

%% `update_available => false' is NervesHub saying there is nothing to do.
an_unavailable_update_starts_nothing_test() ->
    {Agent, JoinRef} = join(#{}),

    send_update(Agent, JoinRef, #{<<"update_available">> => false}),
    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertEqual(no_event, next_event(300)),

    nh_agent:stop(Agent).

%% An application that would rather decide for itself gets the message and
%% nothing else.
manual_updates_are_only_reported_test() ->
    {Agent, JoinRef} = join(#{updates => manual}),

    send_update(Agent, JoinRef, #{
        <<"update_available">> => true,
        <<"firmware_url">> => <<"http://example.com/fw.avm">>
    }),

    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertEqual(no_event, next_event(300)),

    nh_agent:stop(Agent).

%% Reads sent frames until one carries the named event.
wait_for_event(Event, Timeout) ->
    case next_sent(Timeout) of
        nothing_sent ->
            ?assert(false);
        Frame ->
            case json:decode(Frame) of
                [_, _, _, Event, Payload] -> Payload;
                _Other -> wait_for_event(Event, Timeout)
            end
    end.

%% ------------------------------------------------------------------ console

%% Joins both topics and answers both joins, returning the console's join ref.
join_with_console() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{console => true})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [DeviceJoinRef, DeviceRef, _, _, _] = json:decode(next_sent(1000)),
    [ConsoleJoinRef, ConsoleRef, ConsoleTopic, _, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"console">>, ConsoleTopic),

    ok = reply(Agent, DeviceJoinRef, DeviceRef, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),
    ok = reply(Agent, ConsoleJoinRef, ConsoleRef, <<"console">>),

    {Agent, ConsoleJoinRef}.

reply(Agent, JoinRef, Ref, Topic) ->
    Frame = json:encode([
        JoinRef,
        Ref,
        Topic,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => #{}}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}},
    ok.

send_console(Agent, JoinRef, Event, Payload) ->
    Frame = json:encode([JoinRef, null, <<"console">>, Event, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% A remote console is a capability, so it is asked for rather than assumed.
no_console_topic_unless_asked_for_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [_, _, Topic, <<"phx_join">>, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% A console that says nothing until you type looks like one that is broken,
%% and the commands are not guessable.
joining_the_console_sends_a_banner_test() ->
    {Agent, _JoinRef} = join_with_console(),

    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"help">>)),
    ?assertMatch({_, _}, binary:match(Data, nh_console:prompt())),

    nh_agent:stop(Agent).

keystrokes_are_echoed_back_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"dn">>, #{<<"data">> => <<"info">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertEqual(<<"info">>, Data),

    nh_agent:stop(Agent).

a_command_answers_on_the_console_topic_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"dn">>, #{<<"data">> => <<"help\r">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),

    ?assertMatch({_, _}, binary:match(Data, <<"reboot">>)),
    ?assertMatch({_, _}, binary:match(Data, nh_console:prompt())),

    nh_agent:stop(Agent).

restart_resets_the_session_rather_than_the_device_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"restart">>, #{}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"Console restarted">>)),

    nh_agent:stop(Agent).

%% Quietly accepting bytes nothing will ever write would be worse than saying so.
file_transfer_is_declined_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"file-data/start">>, #{<<"filename">> => <<"x">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"not supported">>)),

    nh_agent:stop(Agent).

%% Resizing a terminal is routine and must not read as an unhandled message.
window_size_is_accepted_quietly_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"window_size">>, #{<<"height">> => 24, <<"width">> => 80}),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% --------------------------------------------------------------- extensions

%% Joins device + extensions, answering both. Returns the extensions join ref.
join_with_extensions(Enabled, AttachList) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{extensions => Enabled})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [DeviceJoinRef, DeviceRef, _, _, _] = json:decode(next_sent(1000)),
    [ExtJoinRef, ExtRef, ExtTopic, <<"phx_join">>, Offered] = json:decode(next_sent(1000)),
    ?assertEqual(<<"extensions">>, ExtTopic),

    ok = reply(Agent, DeviceJoinRef, DeviceRef, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),

    Frame = json:encode([
        ExtJoinRef,
        ExtRef,
        <<"extensions">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => AttachList}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}},
    ?assertMatch({extensions_attached, _}, next_event(1000)),

    %% NervesHub waits for `<key>:attached' before it starts an extension, so
    %% each attached one is confirmed before anything else goes out.
    lists:foreach(
        fun(Name) ->
            [_, _, <<"extensions">>, Event, _] = json:decode(next_sent(1000)),
            ?assertEqual(<<Name/binary, ":attached">>, Event)
        end,
        AttachList
    ),

    {Agent, ExtJoinRef, Offered}.

send_extension(Agent, JoinRef, Event, Payload) ->
    Frame = json:encode([JoinRef, null, <<"extensions">>, Event, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

no_extensions_topic_unless_any_are_enabled_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [_, _, <<"device">>, <<"phx_join">>, _] = json:decode(next_sent(1000)),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

the_join_declares_what_the_device_offers_test() ->
    {Agent, _Ref, Offered} = join_with_extensions([health, geo], [<<"health">>]),

    ?assertEqual([<<"geo">>, <<"health">>], lists:sort(maps:keys(Offered))),
    ?assertEqual(<<"0.0.1">>, maps:get(<<"health">>, Offered)),

    nh_agent:stop(Agent).

a_health_check_is_answered_with_a_report_test() ->
    {Agent, Ref, _} = join_with_extensions([health], [<<"health">>]),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    Payload = wait_for_event(<<"health:report">>, 2000),

    ?assert(maps:is_key(<<"value">>, Payload)),
    ?assert(maps:is_key(<<"metrics">>, maps:get(<<"value">>, Payload))),

    nh_agent:stop(Agent).

%% The platform asking for something it never turned on is not answered.
a_check_for_a_detached_extension_is_ignored_test() ->
    {Agent, Ref, _} = join_with_extensions([health, geo], [<<"geo">>]),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    ?assertEqual(nothing_sent, next_sent(500)),

    nh_agent:stop(Agent).

%% Sent on the extensions topic, and only when logging is attached.
a_log_line_goes_out_on_the_extensions_topic_test() ->
    {Agent, _Ref, _} = join_with_extensions([logging], [<<"logging">>]),

    ok = nerves_hub_link:send_log(Agent, <<"info">>, <<"hello from the bench">>),
    Payload = wait_for_event(<<"logging:send">>, 2000),

    ?assertEqual(<<"info">>, maps:get(<<"level">>, Payload)),
    ?assertEqual(<<"hello from the bench">>, maps:get(<<"message">>, Payload)),
    ?assert(is_binary(maps:get(<<"time">>, maps:get(<<"meta">>, Payload)))),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------------ actions

send_device(Agent, JoinRef, Event) ->
    Frame = json:encode([JoinRef, null, <<"device">>, Event, #{}]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% Only the application knows what identifying looks like on its hardware.
identify_is_reported_to_the_application_test() ->
    {Agent, JoinRef} = join_device(),

    send_device(Agent, JoinRef, <<"identify">>),
    ?assertEqual({identify}, next_event(1000)),

    %% and nothing is sent back: NervesHub asks, it does not wait for an answer
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% NervesHub never learns why a device vanished unless this arrives first.
reboot_announces_itself_before_going_test() ->
    {Agent, JoinRef} = join_device(#{reboot => manual}),

    send_device(Agent, JoinRef, <<"reboot">>),
    ?assertEqual({reboot_requested}, next_event(1000)),

    [_, _, <<"device">>, Event, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"rebooting">>, Event),

    nh_agent:stop(Agent).

%% An application that would rather choose its moment gets the message and the
%% device stays up.
manual_reboot_leaves_the_device_running_test() ->
    {Agent, JoinRef} = join_device(#{reboot => manual}),

    send_device(Agent, JoinRef, <<"reboot">>),
    ?assertEqual({reboot_requested}, next_event(1000)),
    _ = next_sent(1000),

    %% still answering afterwards
    ok = nerves_hub_link:update_progress(Agent, 42),
    [_, _, _, <<"update_progress">>, Payload] = json:decode(next_sent(1000)),
    ?assertEqual(42, maps:get(<<"value">>, Payload)),

    nh_agent:stop(Agent).

join_device() -> join_device(#{}).

join_device(Extra) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(Extra)),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    ok = reply(Agent, JoinRef, Ref, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),
    {Agent, JoinRef}.
