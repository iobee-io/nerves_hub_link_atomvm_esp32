%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
%% A downloader that reports some progress and then never another word, as
%% one waiting on a connection that stopped carrying data.
-module(nh_ota_stalled).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        Owner ! {nh_ota, self(), {progress, 10}},
        receive
        after infinity -> ok
        end
    end).
