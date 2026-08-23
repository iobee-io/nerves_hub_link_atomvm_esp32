%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_signature_tests).

-include_lib("eunit/include/eunit.hrl").

keypair() -> crypto:generate_key(eddsa, ed25519).

archive() -> nh_packbeam_tests:packbeam([{product, <<"blinky">>}, {version, <<"1.2.3">>}]).

signed() ->
    {Pub, Priv} = keypair(),
    {ok, Signed} = nh_signature:sign(archive(), Priv),
    {Pub, Signed}.

signing_is_an_append_test() ->
    {_Pub, Signed} = signed(),
    Archive = archive(),

    ?assert(byte_size(Signed) > byte_size(Archive)),
    %% Nothing before the signature moves, which is what makes the signed range
    %% computable at both ends without agreeing on anything else.
    Prefix = byte_size(Archive) - 16,
    ?assertEqual(binary:part(Archive, 0, Prefix), binary:part(Signed, 0, Prefix)).

verify_returns_the_key_that_matched_test() ->
    {Pub, Signed} = signed(),
    ?assertEqual({ok, Pub}, nh_signature:verify(Signed, [Pub])).

verify_finds_the_key_among_several_test() ->
    {Pub, Signed} = signed(),
    {Other, _} = keypair(),
    {Another, _} = keypair(),

    ?assertEqual({ok, Pub}, nh_signature:verify(Signed, [Other, Pub, Another])).

%% An archive nobody signed and an archive signed by someone else are not the
%% same problem, and a caller may want to treat them differently.
unsigned_and_wrong_key_are_different_test() ->
    {Pub, Signed} = signed(),
    {Other, _} = keypair(),

    ?assertEqual({error, unsigned}, nh_signature:verify(archive(), [Pub])),
    ?assertEqual({error, invalid_signature}, nh_signature:verify(Signed, [Other])).

no_keys_is_not_a_pass_test() ->
    {_Pub, Signed} = signed(),
    ?assertEqual({error, invalid_signature}, nh_signature:verify(Signed, [])).

%% The point of the whole exercise: no single flipped bit in the signed range
%% is ever accepted.
tampering_anywhere_in_the_signed_range_is_caught_test() ->
    {Pub, Signed} = signed(),

    lists:foreach(
        fun(Position) ->
            <<Head:Position/binary, Byte, Tail/binary>> = Signed,
            Tampered = <<Head/binary, (Byte bxor 1), Tail/binary>>,
            ?assertMatch({{error, _}, Position}, {nh_signature:verify(Tampered, [Pub]), Position})
        end,
        %% The magic, an entry header, entry data, and the application spec.
        [4, 30, 100, byte_size(Signed) div 2]
    ).

%% Corruption inside an entry is a signature failure. Corruption of the magic
%% is not -- it stops being a packbeam before there is a signature to check,
%% and reporting that as a bad signature would send someone looking at keys.
tampering_is_reported_as_what_it_is_test() ->
    {Pub, Signed} = signed(),

    Mid = byte_size(Signed) div 2,
    <<Head:Mid/binary, Byte, Tail/binary>> = Signed,
    ?assertEqual(
        {error, invalid_signature},
        nh_signature:verify(<<Head/binary, (Byte bxor 1), Tail/binary>>, [Pub])
    ),

    <<First, Rest/binary>> = Signed,
    ?assertEqual(
        {error, not_a_packbeam}, nh_signature:verify(<<(First bxor 1), Rest/binary>>, [Pub])
    ).

%% A signed archive has to remain something a stock AtomVM can read, or signing
%% would take devices away rather than only adding a check.
a_signed_archive_is_still_a_packbeam_test() ->
    {_Pub, Signed} = signed(),

    ?assertEqual({ok, byte_size(Signed)}, nh_packbeam:byte_length(Signed)),
    ?assertMatch(
        {ok, #{name := <<"blinky">>, vsn := <<"1.2.3">>}}, nh_packbeam:application(Signed)
    ),
    {ok, Entries} = nh_packbeam:scan(Signed),
    ?assert(lists:member(nh_signature:entry_name(), [maps:get(name, E) || E <- Entries])).

%% The signature is a data entry, the class AtomVM skips when it looks for code.
the_signature_entry_is_not_code_test() ->
    {_Pub, Signed} = signed(),
    {ok, Entries} = nh_packbeam:scan(Signed),
    [Entry] = [E || #{name := Name} = E <- Entries, Name =:= nh_signature:entry_name()],

    ?assertEqual(4, maps:get(flags, Entry)),
    ?assertEqual(0, maps:get(flags, Entry) band 1).

strip_gives_back_what_was_signed_test() ->
    {_Pub, Signed} = signed(),
    ?assertEqual({ok, archive()}, nh_signature:strip(Signed)).

%% Re-signing after a key rotation is the same operation as signing.
signing_twice_replaces_rather_than_nests_test() ->
    {_Pub, Signed} = signed(),
    {Pub2, Priv2} = keypair(),
    {ok, Resigned} = nh_signature:sign(Signed, Priv2),

    ?assertEqual(byte_size(Signed), byte_size(Resigned)),
    ?assertEqual({ok, Pub2}, nh_signature:verify(Resigned, [Pub2])),
    ?assertEqual({error, invalid_signature}, nh_signature:verify(Resigned, [element(1, signed())])).

signed_range_ends_where_the_signature_begins_test() ->
    {_Pub, Signed} = signed(),
    {ok, Range, Payload} = nh_signature:signed_range(Signed),

    {ok, Entries} = nh_packbeam:scan(Signed),
    [#{offset := Offset}] = [
        E
     || #{name := Name} = E <- Entries, Name =:= nh_signature:entry_name()
    ],

    ?assertEqual(Offset, byte_size(Range)),
    ?assertMatch(<<"NH1", 1:8, _:64/binary>>, Payload).

%% A scheme AtomVM might define later is additive, not a breaking change.
an_unknown_version_is_reported_test() ->
    {Pub, Signed} = signed(),
    Broken = binary:replace(Signed, <<"NH1", 1:8>>, <<"NH1", 99:8>>),

    ?assertMatch({error, {unsupported_signature_version, 99}}, nh_signature:verify(Broken, [Pub])).

a_bad_private_key_is_refused_test() ->
    ?assertMatch({error, {invalid_private_key, _}}, nh_signature:sign(archive(), <<"short">>)).

signing_something_that_is_not_a_packbeam_test() ->
    {_Pub, Priv} = keypair(),
    ?assertEqual({error, not_a_packbeam}, nh_signature:sign(<<"nope">>, Priv)).

%% ------------------------------------------------------------- public keys

public_key_accepts_an_fwup_pub_file_test() ->
    {Public, _Priv} = keypair(),
    Base64 = <<(base64:encode(Public))/binary, "\n">>,

    ?assertEqual({ok, Public}, nh_signature:public_key(Base64)),
    ?assertEqual({ok, Public}, nh_signature:public_key(binary_to_list(Base64))).

public_key_accepts_raw_bytes_test() ->
    {Public, _Priv} = keypair(),
    ?assertEqual({ok, Public}, nh_signature:public_key(Public)).

%% The keys handed to a device are compiled into its firmware. Quietly taking
%% the public half of a private key would put a signing key on every device in
%% the fleet.
public_key_refuses_a_private_key_test() ->
    {Public, Seed} = keypair(),
    FwupPrivate = base64:encode(<<Seed/binary, Public/binary>>),

    ?assertMatch({error, {not_a_public_key, _}}, nh_signature:public_key(FwupPrivate)).

public_key_refuses_nonsense_test() ->
    ?assertMatch({error, {not_a_public_key, _}}, nh_signature:public_key(<<"not base64 at all!">>)),
    ?assertMatch({error, {not_a_public_key, _}}, nh_signature:public_key(<<"">>)),
    ?assertMatch({error, {not_a_public_key, _}}, nh_signature:public_key(atom)).

%% Verification against a mapped range is the device's path, so it is the one
%% exercised here directly.
verify_parts_checks_a_located_range_test() ->
    {Pub, Signed} = signed(),
    {ok, Range, Payload} = nh_signature:signed_range(Signed),

    ?assertEqual({ok, Pub}, nh_signature:verify_parts(Range, Payload, [Pub])),
    ?assertEqual(
        {error, invalid_signature}, nh_signature:verify_parts(<<"other">>, Payload, [Pub])
    ),
    ?assertEqual({error, malformed_signature}, nh_signature:verify_parts(Range, <<"junk">>, [Pub])).

%% ------------------------------------------------------------- private_key/1

%% fwup writes a 64 byte secret key: a seed followed by its public key. Only
%% the seed signs, and this is what `nh-avm` and `mix nerves_hub.sign` both
%% read a key file with, so they cannot drift.
an_fwup_private_key_yields_the_seed_test() ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),
    Fwup = <<Seed/binary, Public/binary>>,

    ?assertEqual({ok, Seed}, nh_signature:private_key(Fwup)),
    ?assertEqual({ok, Seed}, nh_signature:private_key(base64:encode(Fwup))).

a_bare_seed_is_accepted_test() ->
    {_Public, Seed} = crypto:generate_key(eddsa, ed25519),

    ?assertEqual({ok, Seed}, nh_signature:private_key(Seed)),
    ?assertEqual({ok, Seed}, nh_signature:private_key(base64:encode(Seed))).

%% A key file written by fwup or `nh-avm keygen` ends in a newline.
trailing_whitespace_in_a_key_file_is_ignored_test() ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),
    Encoded = base64:encode(<<Seed/binary, Public/binary>>),

    ?assertEqual({ok, Seed}, nh_signature:private_key(<<Encoded/binary, "\n">>)).

%% The key read here signs, so a key of the wrong length has to be refused
%% rather than truncated into something that produces a signature nothing can
%% verify.
%% Base64 of 48 bytes is 64 characters, and reading raw lengths before trying
%% base64 would take that text for a raw fwup key and hand back its first 32
%% characters as the seed. That signs, and produces a signature nothing can
%% verify, which is the worst shape a key bug can have.
base64_text_is_not_mistaken_for_raw_key_bytes_test() ->
    Encoded = base64:encode(binary:copy(<<0>>, 48)),
    ?assertEqual(64, byte_size(Encoded)),

    ?assertEqual({error, {not_a_private_key, 48}}, nh_signature:private_key(Encoded)).

a_key_of_the_wrong_length_is_refused_test() ->
    ?assertMatch({error, _}, nh_signature:private_key(<<1, 2, 3>>)),
    ?assertMatch(
        {error, {not_a_private_key, 48}},
        nh_signature:private_key(base64:encode(binary:copy(<<0>>, 48)))
    ).

%% `public_key/1` refuses a private key on purpose, because what it parses is
%% compiled into firmware. The two are not interchangeable and this records it.
a_private_key_is_not_a_public_key_test() ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),
    Fwup = base64:encode(<<Seed/binary, Public/binary>>),

    ?assertMatch({error, _}, nh_signature:public_key(Fwup)),
    ?assertMatch({ok, _}, nh_signature:private_key(Fwup)).

%% The point of all of it: a key read this way signs an archive that verifies
%% against the matching public key.
a_key_read_this_way_signs_test() ->
    {Public, Seed} = crypto:generate_key(eddsa, ed25519),
    {ok, Parsed} = nh_signature:private_key(base64:encode(<<Seed/binary, Public/binary>>)),

    {ok, Signed} = nh_signature:sign(archive(), Parsed),

    ?assertMatch({ok, Public}, nh_signature:verify(Signed, [Public])).
