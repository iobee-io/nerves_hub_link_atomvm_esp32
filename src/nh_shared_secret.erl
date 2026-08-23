%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc NervesHub shared-secret authentication headers.
%%
%% NervesHub authenticates a device either with a client certificate or with a
%% shared secret. This builds the headers for the second, which the server reads
%% in `NervesHub.DeviceLink.Authentication'.
%%
%% The signature is a `Plug.Crypto' token, so the device has to reproduce what
%% `Plug.Crypto.sign/4' would have produced:
%%
%% ```
%% Salt    = "NH1:device-socket:shared-secret:connect\n\nx-nh-alg=..\nx-nh-key=..\nx-nh-time=..\n"
%% Key     = PBKDF2-HMAC(Digest, Secret, Salt, Iterations, KeyLength)
%% Payload = term_to_binary({Identifier, SignedAtMs, MaxAge})
%% Token   = "SFMyNTY." ++ b64url(Payload) ++ "." ++ b64url(HMAC(Key, "SFMyNTY." ++ b64url(Payload)))
%% '''
%%
%% Every step is a primitive AtomVM has, except `term_to_binary/1'. That one is
%% written out by hand here rather than called: the payload's shape is fixed, and
%% relying on AtomVM's encoder to agree with OTP's byte for byte — in particular
%% on how it writes a millisecond timestamp, which is too large for INTEGER_EXT
%% and lands in SMALL_BIG_EXT — would be a silent dependency. A mismatch fails
%% as an unexplained `unauthorized' at the socket, which is a bad thing to debug
%% on a device.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_shared_secret).

-export([headers/3, headers/4]).

%% Exported for testing against a known-good token.
-export([salt/3, payload/3, token/2]).

-define(PROTECTED, <<"SFMyNTY">>).

-type option() ::
    {digest, sha256 | sha384 | sha512}
    | {iterations, pos_integer()}
    | {key_length, pos_integer()}
    | {max_age, pos_integer()}
    | {signed_at, integer()}.

%%-----------------------------------------------------------------------------
%% @doc Build the authentication headers for a device.
%%
%% `Identifier' is the device identifier, `Key' the shared secret key (`nhd_..'
%% for a device secret, `nhp_..' for a product one) and `Secret' its secret.
%% @end
%%-----------------------------------------------------------------------------
-spec headers(binary(), binary(), binary()) -> [{binary(), binary()}].
headers(Identifier, Key, Secret) ->
    headers(Identifier, Key, Secret, []).

-spec headers(binary(), binary(), binary(), [option()]) -> [{binary(), binary()}].
headers(Identifier, Key, Secret, Opts) ->
    Digest = proplists:get_value(digest, Opts, sha256),
    Iterations = proplists:get_value(iterations, Opts, 1000),
    KeyLength = proplists:get_value(key_length, Opts, 32),
    MaxAge = proplists:get_value(max_age, Opts, 86400),
    SignedAt = proplists:get_value(signed_at, Opts, erlang:system_time(second)),

    Alg = alg(Digest, Iterations, KeyLength),
    Salt = salt(Alg, Key, SignedAt),

    SigningKey = crypto:pbkdf2_hmac(Digest, Secret, Salt, Iterations, KeyLength),

    %% Plug.Crypto records the signing time in milliseconds, while the header
    %% carries seconds. Both come from the same value, and the salt binds them.
    Payload = payload(Identifier, SignedAt * 1000, MaxAge),

    [
        {<<"x-nh-alg">>, <<"NH1-HMAC-", Alg/binary>>},
        {<<"x-nh-key">>, Key},
        {<<"x-nh-time">>, integer_to_binary(SignedAt)},
        {<<"x-nh-signature">>, token(SigningKey, Payload)}
    ].

%%-----------------------------------------------------------------------------
%% @doc The algorithm string, without the `NH1-HMAC-' prefix.
%% @end
%%-----------------------------------------------------------------------------
alg(Digest, Iterations, KeyLength) ->
    DigestName = upper(atom_to_binary(Digest, utf8)),
    <<DigestName/binary, "-", (integer_to_binary(Iterations))/binary, "-",
        (integer_to_binary(KeyLength))/binary>>.

%% Not `string:uppercase/1'. AtomVM's `string' exports `to_upper/1' and not
%% OTP's `uppercase/1', so calling it works on a host and fails on a device —
%% which is where this has to work. A digest name is ASCII, so this is the whole
%% of what either would do.
upper(Bin) ->
    <<<<(upper_char(C))>> || <<C>> <= Bin>>.

upper_char(C) when C >= $a, C =< $z -> C - 32;
upper_char(C) -> C.

%%-----------------------------------------------------------------------------
%% @doc The salt the key is derived from.
%%
%% It repeats the headers, which is what binds the signature to them: changing
%% `x-nh-time' in flight changes the salt, so the key no longer derives and the
%% signature no longer verifies.
%% @end
%%-----------------------------------------------------------------------------
-spec salt(binary(), binary(), integer()) -> binary().
salt(Alg, Key, SignedAt) ->
    <<
        "NH1:device-socket:shared-secret:connect\n"
        "\n"
        "x-nh-alg=NH1-HMAC-",
        Alg/binary,
        "\n"
        "x-nh-key=",
        Key/binary,
        "\n"
        "x-nh-time=",
        (integer_to_binary(SignedAt))/binary,
        "\n"
    >>.

%%-----------------------------------------------------------------------------
%% @doc The external term format encoding of `{Identifier, SignedAtMs, MaxAge}'.
%% @end
%%-----------------------------------------------------------------------------
-spec payload(binary(), integer(), integer()) -> binary().
payload(Identifier, SignedAtMs, MaxAge) ->
    <<
        %% VERSION_MAGIC, SMALL_TUPLE_EXT, arity 3
        131,
        104,
        3,
        (encode_binary(Identifier))/binary,
        (encode_integer(SignedAtMs))/binary,
        (encode_integer(MaxAge))/binary
    >>.

%%-----------------------------------------------------------------------------
%% @doc Sign a payload the way `Plug.Crypto.MessageVerifier' does.
%% @end
%%-----------------------------------------------------------------------------
-spec token(binary(), binary()) -> binary().
token(SigningKey, Payload) ->
    PlainText = <<?PROTECTED/binary, ".", (base64url(Payload))/binary>>,
    Signature = crypto:mac(hmac, sha256, SigningKey, PlainText),
    <<PlainText/binary, ".", (base64url(Signature))/binary>>.

%% BINARY_EXT: tag, 32 bit big-endian length, bytes.
encode_binary(Bin) ->
    <<109, (byte_size(Bin)):32, Bin/binary>>.

%% Matching what term_to_binary/1 chooses, so that a payload built here is
%% byte-identical to one built on the server.
encode_integer(I) when I >= 0, I =< 255 ->
    %% SMALL_INTEGER_EXT
    <<97, I>>;
encode_integer(I) when I >= -2147483648, I =< 2147483647 ->
    %% INTEGER_EXT, 32 bit big-endian, signed
    <<98, I:32/signed>>;
encode_integer(I) when I >= 0 ->
    %% SMALL_BIG_EXT: tag, byte count, sign, then little-endian digits.
    Digits = little_endian_digits(I),
    <<110, (byte_size(Digits)), 0, Digits/binary>>.

little_endian_digits(0) ->
    <<>>;
little_endian_digits(I) ->
    <<(I band 255), (little_endian_digits(I bsr 8))/binary>>.

%% URL-safe base64 without padding, which is what Plug.Crypto emits. AtomVM's
%% base64 module mirrors OTP's and has no url-safe variant, so translate.
base64url(Bin) ->
    Encoded = base64:encode(Bin),
    <<<<(urlsafe(C))>> || <<C>> <= Encoded, C =/= $=>>.

urlsafe($+) -> $-;
urlsafe($/) -> $_;
urlsafe(C) -> C.
