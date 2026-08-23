%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_metadata_tests).

-include_lib("eunit/include/eunit.hrl").

application() ->
    #{name => <<"blinky">>, vsn => <<"1.2.3">>, description => <<"blinks an LED">>}.

describe_carries_the_application_and_the_digest_test() ->
    Metadata = nh_metadata:describe(application(), <<"abc123">>),

    ?assertEqual(<<"blinky">>, maps:get(app_name, Metadata)),
    ?assertEqual(<<"1.2.3">>, maps:get(app_version, Metadata)),
    ?assertEqual(<<"blinks an LED">>, maps:get(description, Metadata)),
    ?assertEqual(<<"abc123">>, maps:get(avm_sha256, Metadata)).

%% The VM's version, which no packbeam can know. Off-device there is no AtomVM,
%% and reporting nothing is the honest answer rather than a crash.
atomvm_version_is_undefined_off_device_test() ->
    ?assertEqual(undefined, nh_metadata:atomvm_version()).

join_params_are_what_nerves_hub_reads_test() ->
    Params = nh_metadata:join_params(nh_metadata:describe(application(), <<"abc123">>)),

    ?assertEqual(<<"atomvm">>, maps:get(<<"update_tool">>, Params)),
    ?assertEqual(<<"blinky">>, maps:get(<<"atomvm_app_name">>, Params)),
    ?assertEqual(<<"1.2.3">>, maps:get(<<"atomvm_app_version">>, Params)),
    ?assertEqual(<<"abc123">>, maps:get(<<"atomvm_avm_sha256">>, Params)).

%% A key the device could not determine is left out, rather than asserting
%% something it does not know.
join_params_omit_what_the_device_could_not_determine_test() ->
    Params = nh_metadata:join_params(#{app_name => <<"blinky">>, avm_sha256 => <<"abc">>}),

    ?assertEqual(
        [<<"atomvm_app_name">>, <<"atomvm_avm_sha256">>, <<"update_tool">>],
        lists:sort(maps:keys(Params))
    ).

join_params_never_carry_a_uuid_test() ->
    Params = nh_metadata:join_params(nh_metadata:describe(application(), <<"abc123">>)),

    %% NervesHub derives it from the digest, using the same rule it applied to
    %% the uploaded archive.
    ?assertNot(maps:is_key(<<"uuid">>, Params)),
    ?assertNot(maps:is_key(<<"nerves_fw_uuid">>, Params)).

hex_is_lower_case_test() ->
    ?assertEqual(<<"00ff10ab">>, nh_metadata:hex(<<16#00, 16#FF, 16#10, 16#AB>>)).

%% End to end over an archive, the way a device with the whole packbeam in
%% memory would do it.
from_packbeam_describes_an_archive_test() ->
    Archive = nh_packbeam_tests:packbeam([
        {product, <<"blinky">>}, {version, <<"2.0.0">>}
    ]),

    {ok, Metadata} = nh_metadata:from_packbeam(Archive),

    ?assertEqual(<<"blinky">>, maps:get(app_name, Metadata)),
    ?assertEqual(<<"2.0.0">>, maps:get(app_version, Metadata)),
    ?assertEqual(
        nh_metadata:hex(crypto:hash(sha256, Archive)), maps:get(avm_sha256, Metadata)
    ).

%% A partition is bigger than the archive written into it. Hashing the padding
%% would give NervesHub a digest it cannot match to anything it stored.
from_packbeam_hashes_the_archive_not_the_partition_test() ->
    Archive = nh_packbeam_tests:packbeam([]),
    InPartition = <<Archive/binary, (binary:copy(<<16#FF>>, 8192))/binary>>,

    {ok, FromArchive} = nh_metadata:from_packbeam(Archive),
    {ok, FromPartition} = nh_metadata:from_packbeam(InPartition),

    ?assertEqual(maps:get(avm_sha256, FromArchive), maps:get(avm_sha256, FromPartition)),
    ?assertEqual(
        nh_metadata:hex(crypto:hash(sha256, Archive)), maps:get(avm_sha256, FromPartition)
    ).

from_packbeam_reports_a_file_that_is_not_one_test() ->
    ?assertEqual({error, not_a_packbeam}, nh_metadata:from_packbeam(binary:copy(<<0>>, 64))).
