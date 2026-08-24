%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc An `ahttp_client' that serves a binary from memory.
%%
%% `nh_ota' drives the download with `connect', `request' and then `stream' over
%% whatever lands in its mailbox, so this only has to deliver the messages
%% `stream/2' would decode. The body is handed out in chunks to exercise
%% buffering across block boundaries, which is where a streaming writer goes
%% wrong.
-module(nh_ota_fake_http).

-export([serve/1, serve/2, fail_connect/0, stop/0]).
-export([connect/4, request/5, stream/2, close/1]).

-define(NAME, ?MODULE).

%% @equiv serve(Body, 200)
serve(Body) -> serve(Body, 200).

serve(Body, Status) ->
    stop(),
    register(?NAME, spawn(fun() -> loop(#{body => Body, status => Status, connect => ok}) end)),
    ok.

fail_connect() ->
    stop(),
    register(?NAME, spawn(fun() -> loop(#{body => <<>>, status => 200, connect => fail}) end)),
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
        ok ->
            %% The responses this download will see, delivered as one message
            %% so `stream/2' has something to decode.
            self() ! {fake_http, call(responses)},
            {ok, conn};
        fail ->
            {error, refused}
    end.

request(Conn, _Method, _Path, _Headers, _Body) -> {ok, Conn, ref}.

stream(_Conn, {fake_http, Responses}) -> {ok, conn, Responses};
stream(_Conn, _Other) -> unknown.

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
        {From, responses} ->
            From ! {?NAME, responses(State)},
            loop(State)
    end.

%% 1500 bytes at a time, so a 4096 byte block boundary falls mid-chunk.
responses(#{body := Body, status := Status}) ->
    [{status, ref, Status}, {header, ref, {<<"content-type">>, <<"application/octet-stream">>}}] ++
        [{data, ref, Chunk} || Chunk <- chunks(Body, 1500)] ++
        [{done, ref}].

chunks(<<>>, _Size) -> [];
chunks(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunks(<<Chunk:1500/binary, Rest/binary>>, Size) -> [Chunk | chunks(Rest, Size)].
