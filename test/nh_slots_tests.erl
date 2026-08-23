%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_slots_tests).

-include_lib("eunit/include/eunit.hrl").

%% A freshly flashed device has no NVS boot path, and `esp32init' falls back to
%% main.avm. Naming the pair a/b would mean provisioning NVS before first boot.
default_is_what_the_loader_falls_back_to_test() ->
    ?assertEqual(<<"main.avm">>, nh_slots:default()),
    ?assert(nh_slots:is_slot(nh_slots:default())).

other_alternates_test() ->
    ?assertEqual({ok, <<"alt.avm">>}, nh_slots:other(<<"main.avm">>)),
    ?assertEqual({ok, <<"main.avm">>}, nh_slots:other(<<"alt.avm">>)).

%% Writing to "whichever slot is free" could overwrite the running one.
other_refuses_a_slot_it_does_not_know_test() ->
    ?assertEqual({error, {unknown_slot, <<"boot.avm">>}}, nh_slots:other(<<"boot.avm">>)),
    ?assertEqual({error, {unknown_slot, <<"ota_0">>}}, nh_slots:other(<<"ota_0">>)).

%% An update is never written over the running application.
other_is_never_the_running_slot_test() ->
    lists:foreach(
        fun(Slot) ->
            {ok, Target} = nh_slots:other(Slot),
            ?assertNotEqual(Slot, Target),
            ?assert(nh_slots:is_slot(Target))
        end,
        nh_slots:all()
    ).

boot_path_is_what_esp32init_reads_test() ->
    ?assertEqual(<<"/dev/partition/by-name/main.avm">>, nh_slots:boot_path(<<"main.avm">>)),
    ?assertEqual(<<"/dev/partition/by-name/alt.avm">>, nh_slots:boot_path(<<"alt.avm">>)).

boot_path_round_trips_test() ->
    lists:foreach(
        fun(Slot) ->
            ?assertEqual({ok, Slot}, nh_slots:from_boot_path(nh_slots:boot_path(Slot)))
        end,
        nh_slots:all()
    ).

%% A device that has never updated has no stored path, and the caller falls back
%% to the bare default.
from_boot_path_accepts_a_bare_label_test() ->
    ?assertEqual({ok, <<"main.avm">>}, nh_slots:from_boot_path(<<"main.avm">>)),
    ?assertEqual({ok, <<"main.avm">>}, nh_slots:from_boot_path("/dev/partition/by-name/main.avm")).

from_boot_path_reports_something_outside_the_pair_test() ->
    ?assertEqual(
        {error, {unknown_slot, <<"boot.avm">>}},
        nh_slots:from_boot_path(<<"/dev/partition/by-name/boot.avm">>)
    ).
