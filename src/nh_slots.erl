%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The two packbeam partitions an update alternates between.
%%
%% An update never writes over the running application. It writes the whole
%% archive into the slot that is not running, points AtomVM's boot path at it,
%% and reboots — so a download that fails, a power cut halfway through, or an
%% archive that turns out to be corrupt all leave the device booting the
%% firmware it already had.
%%
%% == Why the names are not symmetric ==
%%
%% `esp32init' falls back to `/dev/partition/by-name/main.avm' when NVS holds no
%% boot path, so a device flashed at the factory boots from `main.avm' with
%% nothing provisioned. Naming the pair `a'/`b' would mean every device needed
%% an NVS write before it would boot at all.
%%
%% So the slot a fresh device runs keeps the name the loader already looks for,
%% and the second slot is the one that has to be named. See `nh_flash' for how
%% the running slot is read back.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_slots).

-export([default/0, all/0, other/1, boot_path/1, from_boot_path/1, is_slot/1]).

%% What `esp32init:get_boot_path/0' falls back to.
-define(SLOT_MAIN, <<"main.avm">>).
-define(SLOT_ALT, <<"alt.avm">>).

%% The prefix `esp32init' stores a boot path under, and `atomvm:add_avm_pack_file/2'
%% reads. `esp:partition_read/3' takes the bare label instead.
-define(PATH_PREFIX, <<"/dev/partition/by-name/">>).

%%-----------------------------------------------------------------------------
%% @doc The slot a device boots when nothing has told it otherwise.
%% @end
%%-----------------------------------------------------------------------------
-spec default() -> binary().
default() -> ?SLOT_MAIN.

%%-----------------------------------------------------------------------------
%% @doc Both slots, in no meaningful order.
%% @end
%%-----------------------------------------------------------------------------
-spec all() -> [binary()].
all() -> [?SLOT_MAIN, ?SLOT_ALT].

%%-----------------------------------------------------------------------------
%% @doc Whether a partition label is one of the pair.
%% @end
%%-----------------------------------------------------------------------------
-spec is_slot(binary()) -> boolean().
is_slot(Label) -> lists:member(Label, all()).

%%-----------------------------------------------------------------------------
%% @doc The slot an update should be written into, given the running one.
%%
%% An error rather than a guess when the running slot is not one of the pair: a
%% device booting something else is one this scheme does not describe, and
%% writing to whichever slot happened to be free could overwrite what it is
%% running.
%% @end
%%-----------------------------------------------------------------------------
-spec other(binary()) -> {ok, binary()} | {error, {unknown_slot, binary()}}.
other(?SLOT_MAIN) -> {ok, ?SLOT_ALT};
other(?SLOT_ALT) -> {ok, ?SLOT_MAIN};
other(Label) -> {error, {unknown_slot, Label}}.

%%-----------------------------------------------------------------------------
%% @doc The NVS boot path that makes AtomVM boot a slot.
%% @end
%%-----------------------------------------------------------------------------
-spec boot_path(binary()) -> binary().
boot_path(Slot) -> <<?PATH_PREFIX/binary, Slot/binary>>.

%%-----------------------------------------------------------------------------
%% @doc The slot a stored boot path refers to.
%%
%% Accepts a bare label as well as a full path, because a device that has never
%% been updated has no stored path at all and falls back to `default/0'.
%% @end
%%-----------------------------------------------------------------------------
-spec from_boot_path(binary() | string()) -> {ok, binary()} | {error, {unknown_slot, binary()}}.
from_boot_path(Path) when is_list(Path) ->
    from_boot_path(list_to_binary(Path));
from_boot_path(Path) when is_binary(Path) ->
    Label = nh_flash:label_from_path(Path),
    case is_slot(Label) of
        true -> {ok, Label};
        false -> {error, {unknown_slot, Label}}
    end.
