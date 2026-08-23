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

-define(SEED_SIZE, 32).
-define(PUBLIC_SIZE, 32).

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

verify(#{key := KeyPath, in := In}) ->
    Public = read_public_key(KeyPath),

    case nh_signature:verify(read_file(In), [Public]) of
        {ok, _Key} ->
            io:format("~s: signature is valid~n", [In]),
            halt(0);
        {error, Reason} ->
            die("~s: ~p", [In, Reason])
    end.

keygen(#{priv := PrivPath, pub := PubPath}) ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),

    %% fwup's layout, so these files work with fwup too.
    ok = file:write_file(PrivPath, base64(<<Seed/binary, Public/binary>>)),
    ok = file:write_file(PubPath, base64(Public)),
    ok = file:change_mode(PrivPath, 8#600),

    io:format("wrote ~s and ~s~n", [PrivPath, PubPath]),
    halt(0).

%% ------------------------------------------------------------------- keys

%% Accepts fwup's 64 byte secret key or a bare 32 byte seed.
read_private_key(Path) ->
    case decode_key(Path) of
        <<Seed:?SEED_SIZE/binary, _Public:?PUBLIC_SIZE/binary>> -> Seed;
        <<Seed:?SEED_SIZE/binary>> -> Seed;
        Other -> die("~s: not an Ed25519 private key (~p bytes)", [Path, byte_size(Other)])
    end.

read_public_key(Path) ->
    case decode_key(Path) of
        <<Public:?PUBLIC_SIZE/binary>> -> Public;
        %% Handing over a private key by mistake should work rather than fail
        %% confusingly: the public half is the second one.
        <<_Seed:?SEED_SIZE/binary, Public:?PUBLIC_SIZE/binary>> -> Public;
        Other -> die("~s: not an Ed25519 public key (~p bytes)", [Path, byte_size(Other)])
    end.

decode_key(Path) ->
    Contents = read_file(Path),
    Trimmed = <<<<C>> || <<C>> <= Contents, C =/= $\n, C =/= $\r, C =/= $\s>>,

    try base64:decode(Trimmed) of
        Decoded -> Decoded
    catch
        _:_ -> die("~s: not base64", [Path])
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
