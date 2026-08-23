%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Send what an application prints to NervesHub.
%%
%% `nh_logger' catches what goes through `logger'. This catches `io:format/2',
%% `io:put_chars/1', and Elixir's `IO.puts/1' and `IO.inspect/1' -- which is how
%% a great deal of AtomVM code, including most examples, actually reports what
%% it is doing.
%%
%% ```
%% {ok, Capture} = nh_io_capture:start(#{agent => nerves_hub_link}),
%% ok = nh_io_capture:attach(Capture)
%% '''
%%
%% `attach/1' makes the capture process the calling process's group leader.
%% `io:format/2' resolves `standard_io' to the group leader and sends it an
%% `io_request', so everything that process prints arrives here.
%%
%% Call it from the application's own process, early. `spawn' copies the
%% parent's group leader, so every process started after that call is captured
%% and every one started before it is not.
%%
%% == Sharp edges ==
%%
%% **A missing reply hangs the printer.** `io:execute_request/2' waits for
%% `{io_reply, Ref, _}' in a `receive' with no timeout, so a group leader that
%% does not answer a request blocks the process that printed, permanently.
%% Every request is answered here, including shapes this does not understand,
%% and the handling runs inside a `try' so that a crash still produces a reply.
%% That is why this module answers first and asks questions later.
%%
%% **It must never print through `io'.** Echoing with `io:format/2' would send
%% the capture process a request it is already handling. It echoes with
%% `console:print/1', and makes itself its own group leader so that anything
%% inside it that does reach `io' goes straight to the console instead of back
%% here.
%%
%% **The text is unstructured.** `io:format/2' carries no level, no module and
%% no timestamp, so every line arrives at one level with the time it was
%% received. Where structure matters, use `logger' and `nh_logger'; this is the
%% net for code already written.
%%
%% **Reading is answered with `eof'.** `io:get_line/1' and friends would
%% otherwise wait on a console this does not have.
%%
%% **Attaching another process takes effect later.** `erlang:group_leader/2'
%% is synchronous only for the calling process; for any other it sends a signal
%% and returns, so a process that prints immediately can print somewhere else
%% first. Prefer `attach/1' and inheritance to `attach/2' on a process already
%% running.
%%
%% **`logger_std_h' output is captured too, and duplicates.** `logger' runs its
%% handlers in the process that logged, and `logger_std_h' reports by printing,
%% so with a capture attached every line logged reaches NervesHub twice: once
%% structured from `nh_logger', and once as the text `logger_std_h' printed.
%% `nh_console_h' is `logger_std_h' printing straight to the console instead,
%% and swapping it in resolves this.
%%
%% == What it cannot catch ==
%%
%% ESP-IDF's own logging -- the `I (1234) wifi: ...' lines -- is written to the
%% UART from C and never passes through Erlang.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_io_capture).

-export([start/0, start/1, stop/1, attach/1, attach/2, detach/1]).

-define(DEFAULT_AGENT, nerves_hub_link).
-define(DEFAULT_LEVEL, <<"info">>).

%%-----------------------------------------------------------------------------
%% @equiv start(#{})
%% @end
%%-----------------------------------------------------------------------------
-spec start() -> {ok, pid()}.
start() -> start(#{}).

%%-----------------------------------------------------------------------------
%% @doc Start a capture process.
%%
%% `agent' is the registered name or pid to send to, `level' the level every
%% line is reported at, and `echo' whether to keep printing to the console --
%% on by default, because a device whose console goes quiet the moment you turn
%% this on is a device nobody can debug.
%% @end
%%-----------------------------------------------------------------------------
-spec start(map()) -> {ok, pid()}.
start(Opts) ->
    State = #{
        agent => maps:get(agent, Opts, ?DEFAULT_AGENT),
        level => maps:get(level, Opts, ?DEFAULT_LEVEL),
        echo => maps:get(echo, Opts, true)
    },

    {ok, spawn(fun() -> init(State) end)}.

-spec stop(pid()) -> ok.
stop(Capture) ->
    Capture ! stop,
    ok.

%%-----------------------------------------------------------------------------
%% @equiv attach(Capture, self())
%% @end
%%-----------------------------------------------------------------------------
-spec attach(pid()) -> ok.
attach(Capture) -> attach(Capture, self()).

%%-----------------------------------------------------------------------------
%% @doc Make `Capture' the group leader of `Pid'.
%%
%% Asynchronous for any process other than the caller, so anything `Pid' prints
%% in the meantime goes to its old leader. `attach/1' is synchronous.
%% @end
%%-----------------------------------------------------------------------------
-spec attach(pid(), pid()) -> ok.
attach(Capture, Pid) ->
    true = erlang:group_leader(Capture, Pid),
    ok.

%%-----------------------------------------------------------------------------
%% @doc Hand a process back to the group leader it had before capture.
%%
%% A process that is its own group leader is how AtomVM spells "no group leader"
%% -- `io:put_chars/1' checks for exactly that and calls `console:print/1'
%% instead of sending a request -- so this puts printing back on the console.
%% @end
%%-----------------------------------------------------------------------------
-spec detach(pid()) -> ok.
detach(Pid) ->
    true = erlang:group_leader(Pid, Pid),
    ok.

%% ------------------------------------------------------------------ internals

init(State) ->
    %% Its own leader, so that anything in here reaching `io' prints to the
    %% console rather than queueing a request behind the one being handled.
    _ = erlang:group_leader(self(), self()),
    loop(State).

loop(State) ->
    receive
        {io_request, From, Ref, Request} ->
            %% Answer no matter what. A crash here without a reply would hang
            %% `From' for the life of the device.
            Reply =
                try
                    handle(Request, From, State)
                catch
                    _:_ -> {error, request}
                end,

            From ! {io_reply, Ref, Reply},
            loop(State);
        stop ->
            ok;
        _Other ->
            loop(State)
    end.

handle({put_chars, _Encoding, Chars}, From, State) ->
    write(Chars, From, State);
handle({put_chars, Chars}, From, State) ->
    write(Chars, From, State);
handle({put_chars, _Encoding, Module, Function, Args}, From, State) ->
    write(apply(Module, Function, Args), From, State);
handle({put_chars, Module, Function, Args}, From, State) ->
    write(apply(Module, Function, Args), From, State);
handle({requests, Requests}, From, State) ->
    lists:foldl(fun(Request, _Acc) -> handle(Request, From, State) end, ok, Requests);
%% Nothing here reads from a console, and answering anything else would leave
%% the caller waiting for input that is never coming.
handle({get_line, _Encoding, _Prompt}, _From, _State) ->
    eof;
handle({get_chars, _Encoding, _Prompt, _N}, _From, _State) ->
    eof;
handle({get_until, _Encoding, _Prompt, _M, _F, _As}, _From, _State) ->
    eof;
handle({setopts, _Opts}, _From, _State) ->
    ok;
handle(getopts, _From, _State) ->
    [];
handle(_Unknown, _From, _State) ->
    {error, request}.

write(Chars, From, State) ->
    _ = echo(Chars, State),
    _ = forward(Chars, From, State),
    ok.

echo(Chars, #{echo := true}) ->
    try
        apply(console, print, [Chars])
    catch
        %% No console off a device, which is where the tests run.
        _:_ -> ok
    end;
echo(_Chars, _State) ->
    ok.

forward(Chars, From, State) ->
    case agent(State) of
        undefined ->
            ok;
        Agent when Agent =:= From ->
            %% The agent printing while it sends would be asked to send that
            %% too, and so on.
            ok;
        Agent ->
            Level = maps:get(level, State, ?DEFAULT_LEVEL),
            [send(Agent, Level, Line) || Line <- lines(Chars)],
            ok
    end.

send(Agent, Level, Line) ->
    case nh_ext_logs:line(Level, Line, #{}) of
        {ok, LogLine} -> Agent ! {push_extension, nh_ext_logs:event(), LogLine};
        {error, _Reason} -> ok
    end.

%% Split on newlines rather than buffering until one arrives. A tail with no
%% newline is sent as its own line, which is worse than a terminal would do and
%% better than holding it until something happens to flush it -- on a device,
%% that something may be a crash.
lines(Chars) ->
    case text(Chars) of
        <<>> -> [];
        Text -> [Line || Line <- binary:split(Text, <<"\n">>, [global]), Line =/= <<>>]
    end.

text(Chars) when is_binary(Chars) ->
    Chars;
text(Chars) ->
    try iolist_to_binary(Chars) of
        Binary -> Binary
    catch
        _:_ -> <<>>
    end.

agent(State) ->
    case maps:get(agent, State, ?DEFAULT_AGENT) of
        Pid when is_pid(Pid) -> Pid;
        Name when is_atom(Name) -> whereis(Name);
        _Other -> undefined
    end.
