%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%
%% Runs on the host, against OTP, on purpose.
%%
%% `nh_shared_secret:payload/3' writes external term format by hand so that the
%% device does not depend on AtomVM's encoder agreeing with OTP's. That is only
%% worth anything if something checks the two against each other, which is what
%% this does — on a machine that has the real `term_to_binary/1' to compare with.
%%
-module(nh_shared_secret_tests).

-include_lib("eunit/include/eunit.hrl").

payload_matches_term_to_binary_test_() ->
    Cases = [
        %% A plausible millisecond timestamp: too large for INTEGER_EXT, so it
        %% lands in SMALL_BIG_EXT, which is the encoding most likely to be got
        %% wrong.
        {<<"device-1">>, 1787120842596, 86400},
        {<<"device-1">>, 0, 0},
        {<<"d">>, 255, 255},
        {<<"d">>, 256, 256},
        {<<>>, 2147483647, 2147483647},
        {<<"long-identifier-0123456789">>, 4294967296, 1},
        {<<"x">>, 1099511627776, 90},
        {<<"x">>, 1787120842596000, 86400}
    ],
    [
        {
            lists:flatten(io_lib:format("~p", [Case])),
            ?_assertEqual(
                term_to_binary({Id, Ms, MaxAge}),
                nh_shared_secret:payload(Id, Ms, MaxAge)
            )
        }
     || {Id, Ms, MaxAge} = Case <- Cases
    ].

salt_shape_test() ->
    Salt = nh_shared_secret:salt(<<"SHA256-1000-32">>, <<"nhp_abc">>, 1787120842),
    ?assertEqual(
        <<
            "NH1:device-socket:shared-secret:connect\n"
            "\n"
            "x-nh-alg=NH1-HMAC-SHA256-1000-32\n"
            "x-nh-key=nhp_abc\n"
            "x-nh-time=1787120842\n"
        >>,
        Salt
    ).

headers_test() ->
    Headers = nh_shared_secret:headers(<<"dev-1">>, <<"nhp_abc">>, <<"s3cret">>, [
        {signed_at, 1787120842}
    ]),
    ?assertEqual(<<"NH1-HMAC-SHA256-1000-32">>, proplists:get_value(<<"x-nh-alg">>, Headers)),
    ?assertEqual(<<"nhp_abc">>, proplists:get_value(<<"x-nh-key">>, Headers)),
    ?assertEqual(<<"1787120842">>, proplists:get_value(<<"x-nh-time">>, Headers)),

    Signature = proplists:get_value(<<"x-nh-signature">>, Headers),
    ?assertMatch(<<"SFMyNTY.", _/binary>>, Signature),
    %% Three dot-separated parts, and no base64 padding anywhere.
    ?assertEqual(3, length(binary:split(Signature, <<".">>, [global]))),
    ?assertEqual(nomatch, binary:match(Signature, <<"=">>)).
