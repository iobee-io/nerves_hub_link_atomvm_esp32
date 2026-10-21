%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_agent_port_tests).

-include_lib("eunit/include/eunit.hrl").

%% A transport whose handle is a port, as `open_port' returns on AtomVM 0.7,
%% and whose events come tagged with a pid instead -- what the C port of
%% atomvm_websocket_client did before nerves-hub/atomvm_websocket_client
%% 40c3917.
-export([open/1, send_text/2, close/1]).

open(_Config) ->
    Port = open_port({spawn, "cat"}, []),
    ?MODULE ! {opened, Port},
    {ok, Port}.

send_text(_Port, Frame) ->
    ?MODULE ! {sent, Frame},
    ok.

close(Port) ->
    catch port_close(Port),
    ok.

start() ->
    flush(),
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unregister(Name);
        _ -> ok
    end,
    register(?MODULE, self()),
    {ok, Agent} = nh_agent:start(#{
        url => "wss://example.com/socket/websocket",
        identifier => <<"dev-1">>,
        transport => ?MODULE,
        handler => self(),
        reconnect_backoff => {10, 20}
    }),
    receive
        {opened, _Port} -> ok
    after 1000 -> erlang:error(never_opened)
    end,
    Agent.

%% What earlier tests left in this process's mailbox.
flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

sent() ->
    receive
        {sent, Frame} -> Frame
    after 500 -> nothing_sent
    end.

a_pid_tagging_a_port_handle_is_taken_for_it_test() ->
    Agent = start(),
    Tag = spawn(fun() -> ok end),

    Agent ! {websocket, Tag, connected},
    [_, _, <<"device">>, <<"phx_join">>, _] = json:decode(sent()),

    %% Another pid is another connection, already given up on.
    Agent ! {websocket, spawn(fun() -> ok end), {closed, normal}},
    ?assertEqual(nothing_sent, sent()),
    ?assert(is_process_alive(Agent)),

    nh_agent:stop(Agent),
    unregister(?MODULE).

%% Each connection learns its own name: a reconnect is not held to the last.
a_reconnect_takes_the_new_connections_pid_test() ->
    Agent = start(),
    First = spawn(fun() -> ok end),
    Agent ! {websocket, First, connected},
    _Join = sent(),

    Agent ! {websocket, First, {closed, normal}},
    %% the alias went with the first connection, so this one is taken
    receive
        {opened, _} -> ok
    after 1000 -> erlang:error(never_reopened)
    end,
    Agent ! {websocket, spawn(fun() -> ok end), connected},
    [_, _, <<"device">>, <<"phx_join">>, _] = json:decode(sent()),

    nh_agent:stop(Agent),
    unregister(?MODULE).
