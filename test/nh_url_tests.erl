%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_url_tests).

-include_lib("eunit/include/eunit.hrl").

secret() -> #{shared_secret => {<<"nhp_key">>, <<"secret">>}}.

cert() -> #{client_cert => {<<"cert">>, <<"key">>}}.

%% A shared secret plus whatever the test is about, since the path depends on
%% how the device authenticates.
with(Extra) -> maps:merge(secret(), Extra).

resolve(Config) ->
    {ok, Url} = nh_url:resolve(Config),
    Url.

%% The common case: a device with a shared secret and nothing else said.
a_config_with_nothing_said_reaches_the_hosted_server_test() ->
    ?assertEqual(
        <<"wss://devices.nervescloud.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(secret())
    ).

a_host_is_all_that_is_needed_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{host => <<"nh.example.com">>}))
    ).

%% Encrypted unless the config says otherwise. A shared secret travels in
%% headers, and ws:// puts them in the clear.
the_scheme_defaults_to_wss_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{url => <<"nh.example.com">>}))
    ).

%% A bench server, which is the reason ws:// is worth writing out.
a_scheme_and_port_are_kept_test() ->
    ?assertEqual(
        <<"ws://192.168.1.10:4000/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{url => <<"ws://192.168.1.10:4000">>}))
    ).

%% NervesHub serves the device socket at two paths, and which endpoint is
%% listening depends on how the device authenticates.
a_certificate_goes_to_the_device_endpoint_path_test() ->
    ?assertEqual(
        <<"wss://devices.nervescloud.com/socket/websocket?vsn=2.0.0">>,
        resolve(cert())
    ).

%% The server authenticates on the certificate when one is presented, so the
%% path follows the certificate too.
a_certificate_wins_over_a_shared_secret_test() ->
    ?assertEqual(
        <<"wss://devices.nervescloud.com/socket/websocket?vsn=2.0.0">>,
        resolve(maps:merge(secret(), cert()))
    ).

a_url_written_out_in_full_is_left_alone_test() ->
    Written = <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,

    ?assertEqual(Written, resolve(with(#{url => Written}))).

%% An unusual mount point is a deliberate choice and outranks the default.
a_path_that_is_already_there_is_kept_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/behind/a/proxy?vsn=2.0.0">>,
        resolve(with(#{url => <<"wss://nh.example.com/behind/a/proxy">>}))
    ).

a_bare_slash_is_a_host_with_no_path_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{url => <<"wss://nh.example.com/">>}))
    ).

%% Without vsn the server answers in the v1 wire format, which brackets
%% messages differently from what nh_channel writes.
the_wire_version_is_added_when_missing_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{url => <<"wss://nh.example.com/device-socket/websocket">>}))
    ).

a_query_that_is_already_there_is_kept_test() ->
    Written = <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0&extra=1">>,

    ?assertEqual(Written, resolve(with(#{url => Written}))).

%% A query can contain slashes, and taking the path out first would eat them.
a_query_containing_slashes_survives_test() ->
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?token=a/b/c">>,
        resolve(with(#{url => <<"wss://nh.example.com?token=a/b/c">>}))
    ).

%% Elixir writes charlists, so both shapes arrive in practice.
a_string_is_accepted_as_well_as_a_binary_test() ->
    ?assertEqual(
        <<"ws://192.168.1.10:4000/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{url => "ws://192.168.1.10:4000"}))
    ),
    ?assertEqual(
        <<"wss://nh.example.com/device-socket/websocket?vsn=2.0.0">>,
        resolve(with(#{host => "nh.example.com"}))
    ).

%% They are the same field at different levels of detail, so both together is
%% a contradiction rather than something to quietly pick a winner from.
url_and_host_together_are_refused_test() ->
    Config = with(#{url => <<"wss://a.example.com">>, host => <<"b.example.com">>}),

    ?assertEqual({error, {conflicting_config, [url, host]}}, nh_url:resolve(Config)).

an_empty_url_or_host_is_refused_test() ->
    ?assertEqual({error, {empty_config, url}}, nh_url:resolve(with(#{url => <<>>}))),
    ?assertEqual({error, {empty_config, host}}, nh_url:resolve(with(#{host => ""}))).
