%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_logs_tests).

-include_lib("eunit/include/eunit.hrl").

event_is_the_scoped_name_test() ->
    ?assertEqual(<<"logging:send">>, nh_ext_logs:event()).

line_carries_level_and_message_test() ->
    {ok, Line} = nh_ext_logs:line(<<"info">>, <<"hello">>),

    ?assertEqual(<<"info">>, maps:get(<<"level">>, Line)),
    ?assertEqual(<<"hello">>, maps:get(<<"message">>, Line)).

%% NervesHub calls String.to_integer/1 then DateTime.from_unix(:microsecond).
%% An integer is refused and milliseconds land in 1970, so both matter.
time_is_a_string_of_microseconds_test() ->
    {ok, Line} = nh_ext_logs:line(<<"info">>, <<"hello">>),
    Time = maps:get(<<"time">>, maps:get(<<"meta">>, Line)),

    ?assert(is_binary(Time)),
    Micros = binary_to_integer(Time),
    Seconds = Micros div 1000000,

    %% Seconds would be a thousand times too small if this were milliseconds.
    ?assert(Seconds > 1700000000),
    ?assert(Seconds < 4000000000).

meta_is_carried_through_as_strings_test() ->
    {ok, Line} = nh_ext_logs:line(<<"error">>, <<"boom">>, #{module => <<"nh_agent">>, line => 42}),
    Meta = maps:get(<<"meta">>, Line),

    ?assertEqual(<<"nh_agent">>, maps:get(<<"module">>, Meta)),
    ?assertEqual(<<"42">>, maps:get(<<"line">>, Meta)).

%% The timestamp is the one field that decides whether the line is kept at all.
meta_cannot_replace_the_timestamp_test() ->
    {ok, Line} = nh_ext_logs:line(<<"info">>, <<"hi">>, #{<<"time">> => <<"0">>}),
    Time = maps:get(<<"time">>, maps:get(<<"meta">>, Line)),

    ?assertNotEqual(<<"0">>, Time),
    ?assert(binary_to_integer(Time) div 1000000 > 1700000000).

a_line_with_no_meta_still_has_a_time_test() ->
    {ok, Line} = nh_ext_logs:line(<<"info">>, <<"hi">>),
    ?assertEqual([<<"time">>], maps:keys(maps:get(<<"meta">>, Line))).
