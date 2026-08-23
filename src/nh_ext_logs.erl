%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The logging extension.
%%
%% Sends device log lines to NervesHub, which stores them against the device and
%% makes them searchable. One direction only: nothing is ever sent back.
%%
%% ```
%% logging:send  #{level, message, meta}   device -> server
%% '''
%%
%% == The timestamp is not optional ==
%%
%% NervesHub does not stamp a log line on arrival. `LogLine.changeset/1' takes
%% `timestamp' if it is there, otherwise reads `meta.time', and otherwise leaves
%% the line without one — where it fails a required-field validation and is
%% dropped silently.
%%
%% `meta.time' must be a **string** holding **microseconds** since the epoch:
%% the server calls `String.to_integer/1` then `DateTime.from_unix(:microsecond)`,
%% so an integer is not accepted and milliseconds land in 1970. `line/2` builds
%% it, which is the point of this module — the shape is easy to get wrong and
%% wrong is invisible from the device.
%%
%% A device whose clock is not set has no honest timestamp to give, so no line
%% is sent rather than a line dated 1970. See `nh_ext_health:timestamp/0' for
%% the same rule.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ext_logs).

-export([line/2, line/3, line_at/4, event/0]).

%% Anything below the epoch-plus-a-few-decades is a clock that was never set.
-define(EARLIEST_PLAUSIBLE_TIME, 1700000000).

%%-----------------------------------------------------------------------------
%% @doc The scoped event a log line is sent as.
%% @end
%%-----------------------------------------------------------------------------
-spec event() -> binary().
event() -> <<"logging:send">>.

%%-----------------------------------------------------------------------------
%% @equiv line(Level, Message, #{})
%% @end
%%-----------------------------------------------------------------------------
-spec line(binary(), binary()) -> {ok, map()} | {error, no_clock}.
line(Level, Message) -> line(Level, Message, #{}).

%%-----------------------------------------------------------------------------
%% @doc Build a log line NervesHub will accept.
%%
%% `Meta' is merged under the timestamp rather than over it, so a caller cannot
%% accidentally replace the one field that decides whether the line is kept.
%% @end
%%-----------------------------------------------------------------------------
-spec line(binary(), binary(), map()) -> {ok, map()} | {error, no_clock}.
line(Level, Message, Meta) ->
    case micros() of
        undefined -> {error, no_clock};
        Micros -> line_at(Level, Message, Meta, Micros)
    end.

%%-----------------------------------------------------------------------------
%% @doc Build a log line stamped with a time the caller already has.
%%
%% `logger' hands a handler the moment the event was created, in microseconds,
%% which is exactly what NervesHub wants. Using it rather than reading the clock
%% again keeps a line stamped when it happened rather than when it was sent.
%% @end
%%-----------------------------------------------------------------------------
-spec line_at(binary(), binary(), map(), integer()) -> {ok, map()} | {error, no_clock}.
line_at(_Level, _Message, _Meta, Micros) when
    not is_integer(Micros); Micros div 1000000 =< ?EARLIEST_PLAUSIBLE_TIME
->
    {error, no_clock};
line_at(Level, Message, Meta, Micros) ->
    {ok, #{
        <<"level">> => Level,
        <<"message">> => Message,
        <<"meta">> => maps:merge(stringify(Meta), #{<<"time">> => integer_to_binary(Micros)})
    }}.

micros() ->
    try erlang:system_time(microsecond) of
        Micros when Micros div 1000000 > ?EARLIEST_PLAUSIBLE_TIME -> Micros;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% NervesHub stores meta as a string map. A number sent here is stored as a
%% string anyway, so it is converted where it can still be done sensibly.
stringify(Meta) when is_map(Meta) ->
    maps:from_list([{text(K), text(V)} || {K, V} <- maps:to_list(Meta)]);
stringify(_Meta) ->
    #{}.

text(Bin) when is_binary(Bin) -> Bin;
text(N) when is_integer(N) -> integer_to_binary(N);
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(L) when is_list(L) ->
    try list_to_binary(L) of
        Bin -> Bin
    catch
        _:_ -> <<"?">>
    end;
text(_) ->
    <<"?">>.
