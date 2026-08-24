%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Command line signing for packbeam archives.
%%
%% ```
%% nh-avm sign   --key fwup-key.priv --in app.avm --out app-signed.avm
%% nh-avm verify --key fwup-key.pub  --in app-signed.avm
%% nh-avm keygen --priv my.priv --pub my.pub
%% '''
%%
%% == The keys are fwup keys ==
%%
%% Deliberately. An fwup private key is 64 bytes: a 32 byte Ed25519 seed
%% followed by its public key, which is libsodium's layout. The seed is what
%% signs, and the trailing half is byte for byte the `.pub' file — so an
%% organization signs packbeams with the key it already uses for fwup, and
%% NervesHub verifies against the organization key it already stores. Signing
%% AtomVM firmware adds no key management at all.
%%
%% `keygen' writes the same format for anyone not already using fwup, and
%% `fwup -g' produces files this accepts.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_avm_sign).

-export([main/1]).

%% Every path ends in `halt/1', which is what `no_return()' says. Without it
%% dialyzer reports four "has no local return" warnings for code that is doing
%% exactly what a command line tool should.
-spec main([string()]) -> no_return().
main(["sign" | Args]) -> run(fun sign/1, Args, [key, in, out]);
main(["verify" | Args]) -> run(fun verify/1, Args, [key, in]);
main(["keygen" | Args]) -> run(fun keygen/1, Args, [priv, pub]);
main(_Args) -> usage().

usage() ->
    io:format(
        "nh-avm -- sign AtomVM packbeam archives for NervesHub~n~n"
        "  nh-avm sign   --key <priv> --in <archive.avm> --out <signed.avm>~n"
        "  nh-avm verify --key <pub>  --in <archive.avm>~n"
        "  nh-avm keygen --priv <file> --pub <file>~n~n"
        "Keys are fwup keys. Sign with fwup-key.priv, and NervesHub verifies~n"
        "against the organization key it already holds.~n"
    ),
    halt(1).

-spec run(fun((map()) -> no_return()), [string()], [atom()]) -> no_return().
run(Fun, Args, Required) ->
    case parse(Args, #{}) of
        {ok, Options} ->
            case [Name || Name <- Required, not maps:is_key(Name, Options)] of
                [] -> Fun(Options);
                Missing -> die("missing: ~s", [join([atom_to_list(N) || N <- Missing])])
            end;
        error ->
            usage()
    end.

parse([], Options) ->
    {ok, Options};
parse([[$-, $- | Name], Value | Rest], Options) ->
    parse(Rest, maps:put(list_to_atom(Name), Value, Options));
parse(_Other, _Options) ->
    error.

-spec sign(map()) -> no_return().
sign(#{key := KeyPath, in := In, out := Out}) ->
    Seed = read_private_key(KeyPath),
    Archive = read_file(In),

    case nh_signature:sign(Archive, Seed) of
        {ok, Signed} ->
            ok = file:write_file(Out, Signed),
            io:format("signed ~s -> ~s (~p bytes, +~p)~n", [
                In, Out, byte_size(Signed), byte_size(Signed) - byte_size(Archive)
            ]),
            halt(0);
        {error, Reason} ->
            die("could not sign: ~p", [Reason])
    end.

-spec verify(map()) -> no_return().
verify(#{key := KeyPath, in := In}) ->
    Public = read_public_key(KeyPath),

    case nh_signature:verify(read_file(In), [Public]) of
        {ok, _Key} ->
            io:format("~s: signature is valid~n", [In]),
            halt(0);
        {error, Reason} ->
            die("~s: ~p", [In, Reason])
    end.

-spec keygen(map()) -> no_return().
keygen(#{priv := PrivPath, pub := PubPath}) ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),

    %% fwup's layout, so these files work with fwup too.
    ok = file:write_file(PrivPath, base64(<<Seed/binary, Public/binary>>)),
    ok = file:write_file(PubPath, base64(Public)),
    ok = file:change_mode(PrivPath, 8#600),

    io:format("wrote ~s and ~s~n", [PrivPath, PubPath]),
    halt(0).

%% ------------------------------------------------------------------- keys

%% Parsing lives in `nh_signature' so that anything else reading a key file
%% reaches the same conclusion this does.
read_private_key(Path) ->
    case nh_signature:private_key(read_file(Path)) of
        {ok, Seed} -> Seed;
        {error, Reason} -> die("~s: ~p", [Path, Reason])
    end.

read_public_key(Path) ->
    Contents = read_file(Path),

    case nh_signature:public_key(Contents) of
        {ok, Public} ->
            Public;
        {error, _} ->
            %% Handing over a private key by mistake should work rather than
            %% fail confusingly. `public_key/1' refuses one, because what it
            %% parses ends up in firmware, so derive the public half here.
            case nh_signature:private_key(Contents) of
                {ok, Seed} ->
                    {Public, _Seed} = crypto:generate_key(eddsa, ed25519, Seed),
                    Public;
                {error, Reason} ->
                    die("~s: ~p", [Path, Reason])
            end
    end.

base64(Bin) -> <<(base64:encode(Bin))/binary, "\n">>.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> Contents;
        {error, Reason} -> die("~s: ~p", [Path, Reason])
    end.

die(Format, Args) ->
    io:format(standard_error, "nh-avm: " ++ Format ++ "~n", Args),
    halt(1).

join([One]) -> One;
join([One | Rest]) -> One ++ ", " ++ join(Rest).
