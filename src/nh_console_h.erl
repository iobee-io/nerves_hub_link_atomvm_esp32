%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc `logger_std_h', printing past the group leader.
%%
%% Only needed alongside `nh_io_capture'. `logger' runs its handlers in the
%% process that logged, and `logger_std_h' prints with `io:format/2', so with a
%% capture attached its output is captured as well -- and every line logged
%% arrives at NervesHub twice, once structured from `nh_logger' and once as the
%% text `logger_std_h' just printed.
%%
%% This prints the same line with `console:print/1', which is what `io' itself
%% falls back to when a process has no group leader. Nothing is sent, so the
%% console shows every log line and NervesHub gets one copy, from `nh_logger'.
%%
%% ```
%% logger_manager:start_link(#{
%%     log_level => info,
%%     logger => [
%%         {handler, default, nh_console_h, #{level => info}},
%%         nh_logger:handler(#{level => info})
%%     ]
%% })
%% '''
%%
%% Without a capture attached, `logger_std_h' does the same job and this is not
%% worth swapping in.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_console_h).

-export([log/2, handler/0, handler/1]).

%%-----------------------------------------------------------------------------
%% @equiv handler(#{level => info})
%% @end
%%-----------------------------------------------------------------------------
-spec handler() -> tuple().
handler() -> handler(#{level => info}).

%%-----------------------------------------------------------------------------
%% @doc The handler entry to put in `logger_manager''s config.
%%
%% Under the id `default', because that is the slot `logger_std_h' occupies and
%% this replaces it. `logger_manager' adds `logger_std_h' itself when no handler
%% claims that id, so an entry under any other name gets both -- and every line
%% is printed twice.
%% @end
%%-----------------------------------------------------------------------------
-spec handler(map()) -> tuple().
handler(Config) ->
    {handler, default, ?MODULE, maps:merge(#{level => info}, Config)}.

%%-----------------------------------------------------------------------------
%% @doc The `logger' handler callback.
%% @end
%%-----------------------------------------------------------------------------
-spec log(map(), map()) -> ok.
log(LogEvent, _Config) ->
    #{level := Level, msg := Msg, pid := Pid, timestamp := Timestamp, meta := Meta} = LogEvent,

    print(
        io_lib:format("~s [~p] ~p ~s~s~n", [
            timestamp(Timestamp), Level, Pid, location(Meta), nh_logger:message(Msg)
        ])
    ).

%% The one line that makes this module worth having: `io:put_chars/1' resolves
%% to exactly this when a process has no group leader, and calling it directly
%% is how the line reaches the console without passing a capture.
print(Chars) ->
    try
        apply(console, print, [Chars])
    catch
        _:_ -> ok
    end.

timestamp(Microseconds) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:system_time_to_universal_time(Microseconds, microsecond),

    io_lib:format("~p-~s-~sT~s:~s:~s.~sZ", [
        Year,
        pad(Month),
        pad(Day),
        pad(Hour),
        pad(Minute),
        pad(Second),
        pad_1000((Microseconds rem 1000000) div 1000)
    ]).

pad(N) when N >= 0, N < 10 -> [$0 | integer_to_list(N)];
pad(N) -> integer_to_list(N).

pad_1000(N) when N >= 0, N < 10 -> [$0, $0 | integer_to_list(N)];
pad_1000(N) when N >= 0, N < 100 -> [$0 | integer_to_list(N)];
pad_1000(N) -> integer_to_list(N).

location(#{location := #{mfa := {Module, Function, Arity}}}) ->
    io_lib:format("~p:~p/~p ", [Module, Function, Arity]);
location(_Meta) ->
    "".
