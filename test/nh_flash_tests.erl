%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_flash_tests).

-include_lib("eunit/include/eunit.hrl").

%% There is no esp module off a device, which is what makes the rest of the
%% library testable here.
unavailable_off_device_test() ->
    ?assertNot(nh_flash:available()),
    ?assertEqual({error, no_flash_access}, nh_flash:read_metadata(<<"main.avm">>)).

%% `esp32init' records a path; `esp:partition_read/3' takes a label.
label_from_path_takes_the_last_component_test() ->
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path(<<"/dev/partition/by-name/main.avm">>)),
    ?assertEqual(<<"app_b.avm">>, nh_flash:label_from_path(<<"/dev/partition/by-name/app_b.avm">>)),
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path("/dev/partition/by-name/main.avm")).

label_from_path_handles_a_bare_label_test() ->
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path(<<"main.avm">>)),
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path(<<"/main.avm/">>)).

label_from_path_falls_back_rather_than_returning_nothing_test() ->
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path(<<"">>)),
    ?assertEqual(<<"main.avm">>, nh_flash:label_from_path(<<"///">>)).

%% NVS is unreadable off a device, so this is the default `esp32init' uses.
boot_partition_falls_back_to_the_default_test() ->
    ?assertEqual(<<"main.avm">>, nh_flash:boot_partition()).

%% Verification maps the signed range out of flash, so there is nothing to do
%% off a device.
verify_signature_needs_a_device_test() ->
    ?assertEqual({error, no_flash_access}, nh_flash:verify_signature(<<"main.avm">>, [])).
