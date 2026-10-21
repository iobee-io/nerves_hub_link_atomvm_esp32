%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that keeps making progress, slower than the stall limit as a
%% whole but never idle for that long, and then finishes.
-module(nh_ota_slow).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() -> report(Owner, 10) end).

report(Owner, 100) ->
    Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}};
report(Owner, Percent) ->
    Owner ! {nh_ota, self(), {progress, Percent}},
    timer:sleep(60),
    report(Owner, Percent + 10).
