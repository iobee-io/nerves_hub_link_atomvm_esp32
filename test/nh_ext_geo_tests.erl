%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_geo_tests).

-include_lib("eunit/include/eunit.hrl").

%% A real response from whenwhere.nerves-project.org.
body() ->
    <<
        "{\"now\":\"2026-08-22T23:03:21.553Z\",\"time_zone\":\"Pacific/Auckland\","
        "\"latitude\":\"-36.88690\",\"longitude\":\"174.76900\",\"country\":\"NZ\","
        "\"country_region\":\"AUK\",\"city\":\"Auckland\",\"address\":\"182.48.134.168:56733\"}"
    >>.

event_is_the_scoped_name_test() ->
    ?assertEqual(<<"geo:location:update">>, nh_ext_geo:event()).

%% The service sends coordinates as strings; the platform draws them on a map.
coordinates_are_sent_as_numbers_test() ->
    Location = nh_ext_geo:parse_response(body()),

    ?assertEqual(<<"geoip">>, maps:get(<<"source">>, Location)),
    ?assertEqual(-36.8869, maps:get(<<"latitude">>, Location)),
    ?assertEqual(174.769, maps:get(<<"longitude">>, Location)).

%% A change at the service should show up as odd data, not as no data.
an_unparseable_coordinate_is_passed_through_test() ->
    Location = nh_ext_geo:parse_response(<<"{\"latitude\":\"north\",\"longitude\":2}">>),

    ?assertEqual(<<"north">>, maps:get(<<"latitude">>, Location)),
    ?assertEqual(2, maps:get(<<"longitude">>, Location)).

%% A device that answers nothing and one that cannot resolve look identical
%% from the platform, so the failure is reported.
a_response_without_coordinates_is_an_error_test() ->
    Location = nh_ext_geo:parse_response(<<"{\"city\":\"Auckland\"}">>),

    ?assertEqual(<<"NO_LOCATION">>, maps:get(<<"error_code">>, Location)),
    ?assert(maps:is_key(<<"error_description">>, Location)).

undecodable_json_is_an_error_test() ->
    Location = nh_ext_geo:parse_response(<<"not json at all">>),
    ?assertEqual(<<"BAD_RESPONSE">>, maps:get(<<"error_code">>, Location)).

a_bad_url_is_reported_rather_than_crashing_test() ->
    Location = nh_ext_geo:resolve(<<"ftp://example.com/">>),
    ?assertEqual(<<"BAD_URL">>, maps:get(<<"error_code">>, Location)).

the_default_is_the_nerves_project_service_test() ->
    ?assertMatch(
        {_, _}, binary:match(nh_ext_geo:default_url(), <<"whenwhere.nerves-project.org">>)
    ).
