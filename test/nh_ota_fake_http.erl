%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc An `ahttp_client' that serves a binary from memory.
%%
%% `nh_ota' drives the download with `connect', `request' and then `recv', so
%% this hands back one batch of responses per call. The body is handed out in
%% chunks to exercise buffering across block boundaries, which is where a
%% streaming writer goes wrong.
%%
%% `serve_cut/2' cuts each connection in turn: `{At, stall}' stops handing out
%% data after byte `At' of the body and never answers again, `{At, close}'
%% closes there. A request with `Range: bytes=N-' gets 206 and the body from
%% `N'; `ranges/0' says what each request asked for.
-module(nh_ota_fake_http).

-export([serve/1, serve/2, serve_cut/2, fail_connect/0, ranges/0, stop/0]).
-export([connect/4, request/5, recv/2, close/1]).

-define(NAME, ?MODULE).

%% @equiv serve(Body, 200)
serve(Body) -> serve(Body, 200).

serve(Body, Status) -> start(#{connect => ok, body => Body, status => Status, cuts => []}).

serve_cut(Body, Cuts) -> start(#{connect => ok, body => Body, status => 200, cuts => Cuts}).

fail_connect() -> start(#{connect => fail, body => <<>>, status => 200, cuts => []}).

ranges() -> call(ranges).

start(State) ->
    stop(),
    register(?NAME, spawn(fun() -> loop(State#{batches => [], ranges => []}) end)),
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

request(Conn, _Method, _Path, Headers, _Body) ->
    ok = call({request, Headers}),
    {ok, Conn, ref}.

%% A spent body reports the peer close, which is what passive mode gives a
%% caller in place of active mode's `closed' response.
recv(_Conn, _Len) ->
    case call(next) of
        spent ->
            {error, {ssl, closed}};
        stall ->
            receive
            after infinity -> ok
            end;
        Responses ->
            {ok, conn, Responses}
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
        {From, ranges} ->
            From ! {?NAME, maps:get(ranges, State)},
            loop(State);
        {From, {request, Headers}} ->
            #{body := Body, status := Status, cuts := Cuts, ranges := Ranges} = State,
            {Range, From0} = range(Headers),
            {Cut, Later} =
                case Cuts of
                    [] -> {none, []};
                    [C | Cs] -> {C, Cs}
                end,
            From ! {?NAME, ok},
            loop(State#{
                batches => batches(Body, code(Status, From0), From0, Cut),
                cuts => Later,
                ranges => Ranges ++ [Range]
            });
        {From, next} ->
            case maps:get(batches, State) of
                [] ->
                    From ! {?NAME, spent},
                    loop(State);
                [stall | _] ->
                    From ! {?NAME, stall},
                    loop(State);
                [Batch | Rest] ->
                    From ! {?NAME, Batch},
                    loop(State#{batches => Rest})
            end
    end.

range([]) ->
    {none, none};
range([{<<"Range">>, Value}]) ->
    Bin = iolist_to_binary(Value),
    <<"bytes=", Rest/binary>> = Bin,
    [N, <<>>] = binary:split(Rest, <<"-">>),
    {Bin, binary_to_integer(N)}.

%% One batch per `recv', 1500 bytes at a time, so a 4096 byte block boundary
%% falls mid-chunk.
batches(Body, Status, none, Cut) ->
    batches(Body, Status, 0, Cut);
batches(Body, Status, From, none) when is_integer(From) ->
    batches(Body, Status, From, {byte_size(Body), done});
batches(Body, Status, From, {At, How}) ->
    Part = binary:part(Body, From, At - From),
    head(Status) ++ [[{data, ref, Chunk}] || Chunk <- chunks(Part, 1500)] ++ ending(How).

code(Status, none) -> Status;
code(_Status, _From) -> 206.

head(Status) ->
    [[{status, ref, Status}, {header, ref, {<<"content-type">>, <<"application/octet-stream">>}}]].

ending(done) -> [[{done, ref}]];
ending(stall) -> [stall];
ending(close) -> [].

chunks(<<>>, _Size) -> [];
chunks(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunks(<<Chunk:1500/binary, Rest/binary>>, Size) -> [Chunk | chunks(Rest, Size)].
