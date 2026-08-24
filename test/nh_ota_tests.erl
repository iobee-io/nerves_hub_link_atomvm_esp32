%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ota_tests).

-include_lib("eunit/include/eunit.hrl").

unavailable_off_device_test() ->
    ?assertNot(nh_ota:available()),
    ?assertEqual({error, no_flash_access}, nh_ota:apply_update(#{})).

parse_url_splits_what_the_client_needs_test() ->
    ?assertEqual(
        {ok, #{
            protocol => http,
            host => <<"192.168.1.137">>,
            port => 4000,
            path => <<"/firmware/1/abc.avm">>
        }},
        nh_ota:parse_url(<<"http://192.168.1.137:4000/firmware/1/abc.avm">>)
    ).

parse_url_defaults_the_port_to_the_scheme_test() ->
    {ok, #{port := 80, protocol := http}} = nh_ota:parse_url(<<"http://example.com/f.avm">>),
    {ok, #{port := 443, protocol := https}} = nh_ota:parse_url(<<"https://example.com/f.avm">>).

parse_url_handles_a_bare_host_test() ->
    ?assertMatch({ok, #{path := <<"/">>}}, nh_ota:parse_url(<<"http://example.com">>)),
    ?assertMatch(
        {ok, #{path := <<"/">>, port := 8080}}, nh_ota:parse_url(<<"http://example.com:8080">>)
    ).

parse_url_keeps_the_query_string_test() ->
    {ok, #{path := Path}} = nh_ota:parse_url(<<"https://h/firmware/a.avm?sig=xyz&t=1">>),
    ?assertEqual(<<"/firmware/a.avm?sig=xyz&t=1">>, Path).

parse_url_accepts_a_string_test() ->
    ?assertMatch({ok, #{host := <<"example.com">>}}, nh_ota:parse_url("http://example.com/f.avm")).

parse_url_refuses_what_it_cannot_handle_test() ->
    ?assertEqual({error, {missing_update_field, firmware_url}}, nh_ota:parse_url(undefined)),
    ?assertMatch({error, {unsupported_url, _}}, nh_ota:parse_url(<<"ftp://example.com/f.avm">>)),
    ?assertMatch({error, {unsupported_url, _}}, nh_ota:parse_url(<<"/firmware/a.avm">>)),
    ?assertMatch({error, {invalid_port, _}}, nh_ota:parse_url(<<"http://h:0/f.avm">>)),
    ?assertMatch({error, {invalid_port, _}}, nh_ota:parse_url(<<"http://h:notaport/f.avm">>)),
    ?assertMatch({error, {invalid_url_authority, _}}, nh_ota:parse_url(<<"http:///f.avm">>)).

%% NervesHub stores a firmware checksum upper case; this library works in lower
%% case. Comparing them literally would reject every good download.
digest_matches_ignores_case_test() ->
    Lower = <<"b0f128ddca6ac62c8b95b7830acf46d2c156f6e9ef8cde41126661a969c3c8ad">>,
    Upper = <<"B0F128DDCA6AC62C8B95B7830ACF46D2C156F6E9EF8CDE41126661A969C3C8AD">>,

    ?assert(nh_ota:digest_matches(Lower, Upper)),
    ?assert(nh_ota:digest_matches(Lower, Lower)),
    ?assert(nh_ota:digest_matches(Upper, Lower)).

digest_matches_rejects_a_different_archive_test() ->
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, <<"bbbb">>)),
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, <<"aaaab">>)).

%% A missing checksum must never pass. An update NervesHub did not describe
%% fully is one to refuse, not one to install unchecked.
digest_matches_refuses_a_missing_checksum_test() ->
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, undefined)),
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, not_a_binary)).

%% ------------------------------------------------------------------ commit/0

%% `commit/0` used to be unable to fail: `nvs_erase` ended in `catch _:_ -> ok`,
%% so a device could report a commit that never happened and leave the pending
%% marker on flash while believing the firmware was validated. The agent has
%% always handled `{error, _}` here -- the branch was simply unreachable.
%%
%% There is no `esp` module on the host, so `apply` raises `undef` and this
%% exercises exactly the path that used to be swallowed.
a_commit_that_cannot_write_nvs_is_reported_test() ->
    ?assertMatch({error, {nvs_erase_failed, _Key, _Reason}}, nh_ota:commit()).
