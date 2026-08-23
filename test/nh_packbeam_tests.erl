%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_packbeam_tests).

-include_lib("eunit/include/eunit.hrl").

%% Shared with the other test modules.
-export([packbeam/1]).

%% Builds a packbeam the same shape `rebar3 atomvm packbeam' produces. The
%% application term is encoded by hand so a test can name an application this
%% node has never heard of.
packbeam(Opts) ->
    Product = proplists:get_value(product, Opts, <<"blinky">>),
    Version = proplists:get_value(version, Opts, <<"1.0.0">>),
    Description = proplists:get_value(description, Opts, <<"a test application">>),
    Modules = proplists:get_value(modules, Opts, [<<"blinky">>]),
    Deps = proplists:get_value(applications, Opts, []),

    Beams = [entry(<<M/binary, ".beam">>, 2, binary:copy(<<16#AA>>, 16)) || M <- Modules],
    Specs = [
        entry(<<N/binary, "/priv/application.bin">>, 4, application_bin(N, V, Description))
     || {N, V} <- [{Product, Version} | Deps]
    ],

    iolist_to_binary([nh_packbeam:magic(), Beams, Specs, terminator()]).

entry(Name, Flags, Data) ->
    NameField = pad4(<<Name/binary, 0>>),
    Padded = pad4(Data),
    Size = 12 + byte_size(NameField) + byte_size(Padded),
    <<Size:32, Flags:32, 0:32, NameField/binary, Padded/binary>>.

%% What `packbeam_api:write_packbeam/2' ends every archive with.
terminator() -> <<0:32, 0:32, 0:32, "end", 0>>.

application_bin(Name, Version, Description) ->
    Term = <<
        131,
        104,
        3,
        (atom_ext(<<"application">>))/binary,
        (atom_ext(Name))/binary,
        (list_ext([
            tuple([atom_ext(<<"description">>), string_ext(Description)]),
            tuple([atom_ext(<<"vsn">>), string_ext(Version)])
        ]))/binary
    >>,
    <<(byte_size(Term)):32, Term/binary>>.

atom_ext(Name) -> <<119, (byte_size(Name)), Name/binary>>.
string_ext(S) -> <<107, (byte_size(S)):16, S/binary>>.
tuple(Elements) -> iolist_to_binary([<<104, (length(Elements))>>, Elements]).
list_ext(Elements) -> iolist_to_binary([<<108, (length(Elements)):32>>, Elements, <<106>>]).

pad4(Bin) ->
    case byte_size(Bin) rem 4 of
        0 -> Bin;
        Rem -> <<Bin/binary, 0:((4 - Rem) * 8)>>
    end.

scan_walks_every_entry_test() ->
    Archive = packbeam([{product, <<"blinky">>}, {modules, [<<"blinky">>, <<"worker">>]}]),
    {ok, Entries} = nh_packbeam:scan(Archive),

    ?assertEqual(
        [<<"blinky.beam">>, <<"worker.beam">>, <<"blinky/priv/application.bin">>],
        [maps:get(name, E) || E <- Entries]
    ),
    ?assertEqual([2, 2, 4], [maps:get(flags, E) || E <- Entries]).

scan_rejects_a_file_without_the_magic_test() ->
    ?assertEqual({error, not_a_packbeam}, nh_packbeam:scan(binary:copy(<<0>>, 64))).

scan_rejects_a_truncated_archive_test() ->
    Archive = packbeam([]),
    Truncated = binary:part(Archive, 0, byte_size(Archive) - 24),
    ?assertEqual({error, truncated_packbeam}, nh_packbeam:scan(Truncated)).

%% The range NervesHub hashed on upload. Getting this wrong by even the four
%% trailing bytes gives the device a digest the server cannot match.
byte_length_covers_the_terminator_test() ->
    Archive = packbeam([]),
    ?assertEqual({ok, byte_size(Archive)}, nh_packbeam:byte_length(Archive)).

byte_length_ignores_whatever_follows_the_archive_test() ->
    Archive = packbeam([]),
    InPartition = <<Archive/binary, (binary:copy(<<16#FF>>, 4096))/binary>>,

    ?assertEqual({ok, byte_size(Archive)}, nh_packbeam:byte_length(InPartition)).

application_reads_the_name_and_version_test() ->
    Archive = packbeam([
        {product, <<"blinky">>}, {version, <<"2.3.4">>}, {description, <<"blinks an LED">>}
    ]),

    ?assertEqual(
        {ok, #{name => <<"blinky">>, vsn => <<"2.3.4">>, description => <<"blinks an LED">>}},
        nh_packbeam:application(Archive)
    ).

%% Nothing in the archive marks the root application, and the plugin writes the
%% project's own ahead of the dependency archives it appends.
application_takes_the_first_spec_test() ->
    Archive = packbeam([
        {product, <<"blinky">>},
        {version, <<"3.0.0">>},
        {applications, [{<<"atomvm_lib">>, <<"0.1.0">>}, {<<"gpio">>, <<"0.2.0">>}]}
    ]),

    {ok, #{name := Name, vsn := Vsn}} = nh_packbeam:application(Archive),

    ?assertEqual(<<"blinky">>, Name),
    ?assertEqual(<<"3.0.0">>, Vsn).

application_reports_an_archive_with_no_spec_test() ->
    Archive = iolist_to_binary([
        nh_packbeam:magic(), entry(<<"blinky.beam">>, 2, <<"code">>), terminator()
    ]),

    ?assertEqual({error, no_application_metadata}, nh_packbeam:application(Archive)).

application_reports_an_unreadable_spec_test() ->
    Archive = iolist_to_binary([
        nh_packbeam:magic(),
        entry(<<"blinky/priv/application.bin">>, 4, <<4:32, 131, 255, 255, 255>>),
        terminator()
    ]),

    ?assertEqual({error, malformed_application_metadata}, nh_packbeam:application(Archive)).

is_application_entry_matches_the_three_component_shape_test() ->
    ?assert(nh_packbeam:is_application_entry(<<"blinky/priv/application.bin">>)),
    ?assertNot(nh_packbeam:is_application_entry(<<"blinky.beam">>)),
    ?assertNot(nh_packbeam:is_application_entry(<<"a/b/priv/application.bin">>)),
    ?assertNot(nh_packbeam:is_application_entry(<<"priv/application.bin">>)).

entry_header_reports_the_terminator_test() ->
    ?assertEqual(terminator, nh_packbeam:entry_header(terminator())),
    ?assertEqual(terminator, nh_packbeam:entry_header(<<0:32, 0:32, 0:32>>)),
    %% A zero flags word ends it too.
    ?assertEqual(terminator, nh_packbeam:entry_header(<<64:32, 0:32, 0:32, "x", 0>>)).

entry_header_refuses_a_size_that_cannot_hold_its_header_test() ->
    ?assertEqual({error, entry_too_small}, nh_packbeam:entry_header(<<4:32, 2:32, 0:32>>)),
    ?assertEqual({error, truncated}, nh_packbeam:entry_header(<<1, 2, 3>>)).

entry_header_refuses_an_unterminated_name_test() ->
    Window = binary:copy(<<$a>>, 64),
    ?assertEqual(
        {error, name_not_terminated},
        nh_packbeam:entry_header(<<128:32, 2:32, 0:32, Window/binary>>)
    ).

%% Arbitrary bytes are a malformed archive, never a crash.
scan_never_raises_on_random_bytes_test() ->
    lists:foreach(
        fun(_) ->
            Bytes = crypto:strong_rand_bytes(rand:uniform(256)),
            Archive = <<(nh_packbeam:magic())/binary, Bytes/binary>>,
            case nh_packbeam:scan(Archive) of
                {ok, _} -> ok;
                {error, _} -> ok
            end
        end,
        lists:seq(1, 200)
    ).
