%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%
%% A NervesHub device running on AtomVM.
%%
%% Brings up WiFi, reports what packbeam it is running, and connects to
%% NervesHub over a shared secret. Everything it prints is what a bench run is
%% for: the metadata read out of flash should match what NervesHub derived from
%% the same archive when it was uploaded.
%%
-module(smart_kiosk_avm).

-export([start/0]).

start() ->
    Config = config:get(),

    io:format("~n=== smart_kiosk_avm ===~n"),
    io:format("AtomVM:        ~p~n", [nh_metadata:atomvm_version()]),
    io:format("boot partition: ~p~n", [nh_flash:boot_partition()]),

    report_firmware(),

    ok = start_network(maps:get(sta, Config)),
    io:format("clock:         ~p~n", [erlang:system_time(second)]),

    Url = maps:get(url, Config),
    io:format("Connecting to ~s~n", [Url]),

    {ok, Agent} = nerves_hub_link:start(#{
        url => Url,
        identifier => maps:get(identifier, Config),
        shared_secret => maps:get(shared_secret, Config),
        verify => none,
        console => true,
        extensions => [health, geo, logging]
    }),

    loop(Agent).

%% The point of the bench run: this is what NervesHub has to be able to match
%% back to the archive it was given.
report_firmware() ->
    case nh_flash:read_metadata() of
        {ok, Metadata} ->
            io:format("app:           ~p ~p~n", [
                maps:get(app_name, Metadata), maps:get(app_version, Metadata)
            ]),
            io:format("avm sha256:    ~s~n", [maps:get(avm_sha256, Metadata)]),
            io:format("join params:   ~p~n", [nh_metadata:join_params(Metadata)]);
        {error, Reason} ->
            io:format("firmware unreadable: ~p~n", [Reason])
    end.

%% Brings up WiFi *and* SNTP. The clock matters as much as the address: a
%% shared-secret signature carries the time it was signed at, NervesHub refuses
%% one older than 90 seconds, and an ESP32 boots at the epoch.
%% Six flashes at 150ms: long enough to spot across a bench, short enough that
%% an operator does not wonder whether it worked.
blink(Pin) ->
    try
        ok = gpio:set_pin_mode(Pin, output),
        blink(Pin, 6)
    catch
        Class:Reason -> io:format("identify: no LED on pin ~p (~p:~p)~n", [Pin, Class, Reason])
    end.

blink(Pin, 0) ->
    gpio:digital_write(Pin, low);
blink(Pin, Remaining) ->
    gpio:digital_write(Pin, high),
    timer:sleep(150),
    gpio:digital_write(Pin, low),
    timer:sleep(150),
    blink(Pin, Remaining - 1).

start_network(StaConfig) ->
    Self = self(),

    Config = [
        {sta, [
            {connected, fun() -> Self ! wifi_connected end},
            {got_ip, fun(IpInfo) -> Self ! {wifi_ip, IpInfo} end},
            {disconnected, fun() -> Self ! wifi_disconnected end}
            | StaConfig
        ]},
        {sntp, [
            {host, "pool.ntp.org"},
            {synchronized, fun(TimeVal) -> Self ! {sntp_synchronized, TimeVal} end}
        ]}
    ],

    {ok, _Pid} = network:start(Config),

    ok = await_ip(30000),
    ok = await_clock(30000).

await_ip(Timeout) ->
    receive
        {wifi_ip, {Address, Netmask, Gateway}} ->
            io:format("IP ~p netmask ~p gateway ~p~n", [Address, Netmask, Gateway]),
            ok;
        wifi_connected ->
            await_ip(Timeout)
    after Timeout ->
        throw({unable_to_start_network, timeout})
    end.

await_clock(Timeout) ->
    receive
        {sntp_synchronized, TimeVal} ->
            io:format("SNTP synchronized: ~p~n", [TimeVal]),
            ok
    after Timeout ->
        throw({clock_never_set, timeout})
    end.

loop(Agent) ->
    receive
        {nerves_hub, {joined, Reply}} ->
            io:format("JOINED: ~p~n", [Reply]),
            loop(Agent);
        {nerves_hub, {extensions_attached, Attached}} ->
            io:format("EXTENSIONS: ~p~n", [Attached]),
            io:format("send_log: ~p~n", [
                nerves_hub_link:send_log(Agent, <<"info">>, <<"smart_kiosk_avm is up">>, #{
                    <<"source">> => <<"bench">>
                })
            ]),
            loop(Agent);
        {nerves_hub, identify} ->
            io:format("~n*** IDENTIFY ***~n~n"),
            %% In its own process: an operator watching for a blink should not
            %% be waiting on whatever else this loop is doing.
            _ = spawn(fun() -> blink(maps:get(led_pin, config:get(), 2)) end),
            loop(Agent);
        {nerves_hub, reboot_requested} ->
            io:format("REBOOT requested by NervesHub~n"),
            loop(Agent);
        {nerves_hub, console_joined} ->
            io:format("CONSOLE: attached~n"),
            loop(Agent);
        {nerves_hub, {update_started, _Pid}} ->
            io:format("UPDATE: downloading~n"),
            loop(Agent);
        {nerves_hub, {firmware_committed, Slot}} ->
            io:format("UPDATE: committed, running ~s~n", [Slot]),
            loop(Agent);
        {nerves_hub, {update_ready, Slot}} ->
            %% The library writes and arms the new slot but does not reboot:
            %% when to restart is the application's call.
            io:format("UPDATE: ~s is armed, rebooting~n", [Slot]),
            timer:sleep(500),
            esp:restart();
        {nerves_hub, {update_failed, Reason}} ->
            io:format("UPDATE FAILED: ~p~n", [Reason]),
            loop(Agent);
        {nerves_hub, {join_error, Reason}} ->
            io:format("JOIN ERROR: ~p~n", [Reason]),
            loop(Agent);
        {nerves_hub, {message, Event, Payload}} ->
            io:format("MESSAGE ~p: ~p~n", [Event, Payload]),
            loop(Agent);
        {nerves_hub, Event} ->
            io:format("nerves_hub: ~p~n", [Event]),
            loop(Agent);
        Other ->
            io:format("other: ~p~n", [Other]),
            loop(Agent)
    end.
