%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc An `ahttp_client' that serves a binary from memory.
%%
%% `nh_ota' drives the download with `connect', `request' and then `recv', so
%% this hands back one batch of responses per call. The body is handed out in
%% chunks to exercise buffering across block boundaries, which is where a
%% streaming writer goes wrong.
-module(nh_ota_fake_http).

-export([serve/1, serve/2, fail_connect/0, stop/0]).
-export([connect/4, request/5, recv/2, close/1]).

-define(NAME, ?MODULE).

%% @equiv serve(Body, 200)
serve(Body) -> serve(Body, 200).

serve(Body, Status) ->
    stop(),
    State = #{connect => ok, batches => batches(Body, Status)},
    register(?NAME, spawn(fun() -> loop(State) end)),
    ok.

fail_connect() ->
    stop(),
    State = #{connect => fail, batches => []},
    register(?NAME, spawn(fun() -> loop(State) end)),
    ok.

stop() ->
    case whereis(?NAME) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            timer:sleep(1),
            ok
    end.

%% ----------------------------------------------- the `ahttp_client' interface

connect(_Protocol, _Host, _Port, _Opts) ->
    case call(connect) of
        ok -> {ok, conn};
        fail -> {error, refused}
    end.

request(Conn, _Method, _Path, _Headers, _Body) -> {ok, Conn, ref}.

%% A spent body reports the peer close, which is what passive mode gives a
%% caller in place of active mode's `closed' response.
recv(_Conn, _Len) ->
    case call(next) of
        spent -> {error, {ssl, closed}};
        Responses -> {ok, conn, Responses}
    end.

close(_Conn) -> ok.

%% ------------------------------------------------------------------ internals

call(Message) ->
    ?NAME ! {self(), Message},
    receive
        {?NAME, Reply} -> Reply
    after 1000 -> error(fake_http_timeout)
    end.

loop(State) ->
    receive
        stop ->
            ok;
        {From, connect} ->
            From ! {?NAME, maps:get(connect, State)},
            loop(State);
        {From, next} ->
            case maps:get(batches, State) of
                [] ->
                    From ! {?NAME, spent},
                    loop(State);
                [Batch | Rest] ->
                    From ! {?NAME, Batch},
                    loop(State#{batches => Rest})
            end
    end.

%% One batch per `recv', 1500 bytes at a time, so a 4096 byte block boundary
%% falls mid-chunk.
batches(Body, Status) ->
    [[{status, ref, Status}, {header, ref, {<<"content-type">>, <<"application/octet-stream">>}}]] ++
        [[{data, ref, Chunk}] || Chunk <- chunks(Body, 1500)] ++
        [[{done, ref}]].

chunks(<<>>, _Size) -> [];
chunks(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunks(<<Chunk:1500/binary, Rest/binary>>, Size) -> [Chunk | chunks(Rest, Size)].
