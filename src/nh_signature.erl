%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Signing a packbeam, and checking one.
%%
%% Packbeam has no signature of its own: `atomvm_packbeam' writes none and
%% `avmpack_is_valid' compares the 24 byte magic and nothing else. This adds one
%% as a convention, in the shape fwup uses -- the signature travels inside the
%% archive, as a sibling of what it signs.
%%
%% ```
%% magic
%% entry, entry, ...                 the archive as built
%% nerves_hub/signature   (data)     appended
%% terminator
%% '''
%%
%% The signed range is every byte before the signature entry begins. That is the
%% one rule a signature scheme has to get right: the signed bytes must exclude
%% the signature itself, or it cannot be checked without knowing what it was.
%%
%% Signing is therefore a pure append. Nothing before the signature moves, so
%% both ends compute the same range without needing to agree on anything else.
%%
%% == Why it does not break anything ==
%%
%% The signature is a data entry, the same class as `priv/application.bin',
%% which AtomVM already skips when it looks for code. A signed archive boots on
%% a stock AtomVM that knows nothing about signing, and on a device that does
%% not verify. Signing can only ever add a check, never take a device away.
%%
%% Reading it is unaffected too: `nh_packbeam:byte_length/1' walks past the
%% entry to the terminator like any other.
%%
%% == Versioned, and namespaced ==
%%
%% AtomVM may define its own signing one day. The entry is named under
%% `nerves_hub/' so it cannot collide with whatever that turns out to be, and
%% the payload leads with a magic and a version so a second scheme is additive
%% rather than a breaking change.
%%
%% ```
%% <<"NH1", Version:8, Signature:64/binary>>
%% '''
%%
%% Ed25519, because that is what an organization's fwup keys already are -- a
%% NervesHub organization can sign a packbeam with the key it already has.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_signature).

-export([entry_name/0, version/0, sign/2, verify/2, verify_parts/3, signed_range/1, strip/1]).
-export([public_key/1, private_key/1, available/0]).

-define(ENTRY_NAME, <<"nerves_hub/signature">>).
-define(MAGIC, <<"NH1">>).
-define(VERSION, 1).

%% The flag `atomvm_packbeam' gives a plain data file.
-define(DATA_FLAG, 4).

%% A zeroed header plus the "end\0" that names it.
-define(TERMINATOR, <<0:32, 0:32, 0:32, "end", 0>>).
-define(TERMINATOR_SIZE, 16).

-define(SIGNATURE_SIZE, 64).
-define(KEY_SIZE, 32).

%%-----------------------------------------------------------------------------
%% @doc The entry a signature is carried in.
%% @end
%%-----------------------------------------------------------------------------
-spec entry_name() -> binary().
entry_name() -> ?ENTRY_NAME.

-spec version() -> pos_integer().
version() -> ?VERSION.

%%-----------------------------------------------------------------------------
%% @doc Sign an archive with an Ed25519 private key, returning a signed archive.
%%
%% Signing an already signed archive replaces the signature rather than nesting
%% one inside another, so re-signing after a key rotation is the same operation.
%% @end
%%-----------------------------------------------------------------------------
-spec sign(binary(), binary()) -> {ok, binary()} | {error, term()}.
sign(Archive, PrivateKey) when byte_size(PrivateKey) =:= ?KEY_SIZE ->
    case unsigned_prefix(Archive) of
        {ok, Prefix} ->
            try crypto:sign(eddsa, none, Prefix, [PrivateKey, ed25519]) of
                Signature when byte_size(Signature) =:= ?SIGNATURE_SIZE ->
                    Payload = <<?MAGIC/binary, ?VERSION:8, Signature/binary>>,
                    {ok, <<Prefix/binary, (entry(Payload))/binary, ?TERMINATOR/binary>>};
                Other ->
                    {error, {unexpected_signature, byte_size(Other)}}
            catch
                Class:Reason -> {error, {sign_failed, Class, Reason}}
            end;
        {error, _} = Error ->
            Error
    end;
sign(_Archive, PrivateKey) ->
    {error, {invalid_private_key, byte_size(PrivateKey)}}.

%%-----------------------------------------------------------------------------
%% @doc Check an archive against a list of Ed25519 public keys.
%%
%% Returns the key that verified, so a caller can record which one it was.
%% `{error, unsigned}' and `{error, invalid_signature}' are deliberately
%% different: an archive nobody signed and an archive signed by someone else are
%% not the same problem.
%% @end
%%-----------------------------------------------------------------------------
-spec verify(binary(), [binary()]) -> {ok, binary()} | {error, term()}.
verify(Archive, PublicKeys) ->
    case signed_range(Archive) of
        none -> {error, unsigned};
        {ok, Signed, Payload} -> verify_parts(Signed, Payload, PublicKeys);
        {error, _} = Error -> Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Check a signature against a range that has already been located.
%%
%% Separate from `verify/2' because a device does not have the archive in
%% memory. It maps the signed range out of flash with `esp:partition_mmap/3',
%% which costs a few words of heap rather than the size of the archive, and
%% hands the mapped binary straight to this.
%%
%% That matters more than it looks. Ed25519 signs a message, not a digest, and
%% neither OTP nor AtomVM offers an incremental verify — so there is no way to
%% check one of these a chunk at a time. Mapping is what makes the scheme
%% workable on a device with a few hundred kilobytes of RAM and an archive
%% measured in hundreds.
%% @end
%%-----------------------------------------------------------------------------
-spec verify_parts(binary(), binary(), [binary()]) -> {ok, binary()} | {error, term()}.
verify_parts(Signed, <<"NH1", ?VERSION:8, Signature:?SIGNATURE_SIZE/binary>>, PublicKeys) ->
    case available() of
        false ->
            {error, verification_unavailable};
        true ->
            case [Key || Key <- PublicKeys, verifies(Signed, Signature, Key)] of
                [Key | _] -> {ok, Key};
                [] -> {error, invalid_signature}
            end
    end;
verify_parts(_Signed, <<"NH1", Version:8, _/binary>>, _PublicKeys) ->
    {error, {unsupported_signature_version, Version}};
verify_parts(_Signed, _Payload, _PublicKeys) ->
    {error, malformed_signature}.

%%-----------------------------------------------------------------------------
%% @doc Whether this VM can check an Ed25519 signature at all.
%%
%% AtomVM's Ed25519 lives behind `AVM_USE_LIBSODIUM', which is **off** in a
%% default build: `crypto:verify(eddsa, ...)' then raises rather than returning
%% false. Firmware built for signature checking has to be running an AtomVM
%% compiled with `-DAVM_USE_LIBSODIUM=ON'.
%%
%% Asked before checking, so that "this VM cannot verify" is never reported as
%% "this firmware is not what it claims to be". They are different problems and
%% they need different fixes, and confusing them sends someone hunting for a
%% tampered archive that does not exist.
%%
%% Probed with a signature that cannot pass, so a supported VM answers false
%% without raising and an unsupported one raises.
%% @end
%%-----------------------------------------------------------------------------
-spec available() -> boolean().
available() ->
    try
        crypto:verify(
            eddsa,
            none,
            <<"probe">>,
            binary:copy(<<0>>, ?SIGNATURE_SIZE),
            [binary:copy(<<0>>, ?KEY_SIZE), ed25519]
        ),
        true
    catch
        _:_ -> false
    end.

verifies(Signed, Signature, Key) when byte_size(Key) =:= ?KEY_SIZE ->
    try
        crypto:verify(eddsa, none, Signed, Signature, [Key, ed25519])
    catch
        %% A key that is the right length but not a point on the curve fails
        %% this candidate, not the archive.
        _:_ -> false
    end;
verifies(_Signed, _Signature, _Key) ->
    false.

%%-----------------------------------------------------------------------------
%% @doc Read a signing key, as the seed `sign/2' wants.
%%
%% Takes fwup's 64 byte secret key or a bare 32 byte seed, base64 or raw. An
%% fwup private key is a seed followed by its public key, which is libsodium's
%% layout, and only the seed is used to sign.
%%
%% The counterpart of `public_key/1', and deliberately not the same function.
%% That one refuses a 64 byte key, because what it parses ends up compiled into
%% firmware and quietly accepting a private key there would put a signing key
%% on every device in the fleet. This one is for a build machine, where a
%% private key is the point.
%% @end
%%-----------------------------------------------------------------------------
-spec private_key(binary() | string()) -> {ok, binary()} | {error, term()}.
private_key(Key) when is_list(Key) ->
    private_key(list_to_binary(Key));
private_key(Key) when is_binary(Key) ->
    %% Base64 first and without falling back on a length mismatch. Checking raw
    %% lengths first looks harmless and is not: base64 of 48 bytes is 64
    %% characters, which would be read as a raw 64 byte key and yield the first
    %% 32 characters of the text as the seed. That signs, and produces a
    %% signature nothing can verify. Raw key bytes are almost never valid
    %% base64, so this way round the ambiguity does not arise.
    seed(
        case base64_decoded(Key) of
            {ok, Decoded} -> Decoded;
            {error, not_base64} -> Key
        end
    );
private_key(Key) ->
    {error, {not_a_key, Key}}.

%% fwup writes a seed followed by its public key; only the seed signs.
seed(<<Seed:?KEY_SIZE/binary, _Public:?KEY_SIZE/binary>>) -> {ok, Seed};
seed(<<Seed:?KEY_SIZE/binary>>) -> {ok, Seed};
seed(Other) -> {error, {not_a_private_key, byte_size(Other)}}.

%% A key file written by fwup or by `nh-avm keygen' is base64 with a trailing
%% newline.
base64_decoded(Key) ->
    Trimmed = <<<<C>> || <<C>> <= Key, C =/= $\n, C =/= $\r, C =/= $\s>>,

    try base64:decode(Trimmed) of
        Decoded -> {ok, Decoded}
    catch
        _:_ -> {error, not_base64}
    end.

%%-----------------------------------------------------------------------------
%% @doc Normalise a configured public key to the 32 raw bytes.
%%
%% Accepts the base64 an fwup `.pub' file holds, or the raw bytes.
%%
%% A 64 byte value is refused rather than helpfully taking its second half.
%% That is the layout of an fwup *private* key, and the keys handed to a device
%% are compiled into firmware -- quietly accepting one would put a signing key
%% on every device in the fleet.
%% @end
%%-----------------------------------------------------------------------------
-spec public_key(binary() | string()) -> {ok, binary()} | {error, term()}.
public_key(Key) when is_list(Key) ->
    public_key(list_to_binary(Key));
public_key(Key) when is_binary(Key), byte_size(Key) =:= ?KEY_SIZE ->
    {ok, Key};
public_key(Key) when is_binary(Key) ->
    Trimmed = <<<<C>> || <<C>> <= Key, C =/= $\n, C =/= $\r, C =/= $\s>>,

    try base64:decode(Trimmed) of
        <<Decoded:?KEY_SIZE/binary>> -> {ok, Decoded};
        Other -> {error, {not_a_public_key, byte_size(Other)}}
    catch
        _:_ -> {error, {not_a_public_key, Key}}
    end;
public_key(Key) ->
    {error, {not_a_public_key, Key}}.

%%-----------------------------------------------------------------------------
%% @doc The bytes a signature covers, and the signature payload itself.
%%
%% `none' when the archive carries no signature entry.
%% @end
%%-----------------------------------------------------------------------------
-spec signed_range(binary()) -> {ok, binary(), binary()} | none | {error, term()}.
signed_range(Archive) ->
    case nh_packbeam:scan(Archive) of
        {ok, Entries} ->
            case [E || #{name := Name} = E <- Entries, Name =:= ?ENTRY_NAME] of
                [#{offset := Offset, data := Payload} | _] ->
                    {ok, binary:part(Archive, 0, Offset), Payload};
                [] ->
                    none
            end;
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc The archive without its signature, as it was before signing.
%% @end
%%-----------------------------------------------------------------------------
-spec strip(binary()) -> {ok, binary()} | {error, term()}.
strip(Archive) ->
    case unsigned_prefix(Archive) of
        {ok, Prefix} -> {ok, <<Prefix/binary, ?TERMINATOR/binary>>};
        {error, _} = Error -> Error
    end.

%% Everything up to where a signature would begin: before an existing signature
%% if there is one, otherwise before the terminator.
unsigned_prefix(Archive) ->
    case signed_range(Archive) of
        {ok, Signed, _Payload} ->
            {ok, Signed};
        none ->
            case nh_packbeam:byte_length(Archive) of
                {ok, Length} when Length >= ?TERMINATOR_SIZE ->
                    {ok, binary:part(Archive, 0, Length - ?TERMINATOR_SIZE)};
                {ok, _Short} ->
                    {error, truncated_packbeam};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% One entry, built the way `packbeam_api:pack_data/1' builds them: a 12 byte
%% header, a NUL terminated name padded to four bytes, then the data.
entry(Data) ->
    NameField = pad4(<<?ENTRY_NAME/binary, 0>>),
    Padded = pad4(Data),
    Size = 12 + byte_size(NameField) + byte_size(Padded),
    <<Size:32, ?DATA_FLAG:32, 0:32, NameField/binary, Padded/binary>>.

pad4(Bin) ->
    case byte_size(Bin) rem 4 of
        0 -> Bin;
        Remainder -> <<Bin/binary, 0:((4 - Remainder) * 8)>>
    end.
