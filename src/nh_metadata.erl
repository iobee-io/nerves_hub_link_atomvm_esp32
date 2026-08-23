%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc What the device reports about the firmware it is running.
%%
%% A Nerves device reports `nerves_fw_*' keys it was built with. An AtomVM
%% device has no such build-time values, and does not need them: the packbeam it
%% booted carries its own application metadata, and the VM underneath reports
%% its version. So the device reports what is actually running rather than what
%% it was compiled to believe.
%%
%% ```
%% atomvm_app_name      <- the packbeam's application name
%% atomvm_app_version   <- its vsn
%% atomvm_avm_sha256    <- SHA-256 of the packbeam
%% atomvm_version       <- erlang:system_info(atomvm_version)
%% '''
%%
%% == Two versions, not one ==
%%
%% `atomvm_app_version' is the firmware NervesHub manages. `atomvm_version' is
%% the VM the firmware runs on, which no packbeam can know and which is replaced
%% on a different schedule by a different mechanism. NervesHub records the
%% second alongside the first rather than confusing them.
%%
%% == No UUID ==
%%
%% NervesHub derives a firmware's UUID from the SHA-256 of the archive when it
%% is uploaded, so a device reporting the digest reports something the server
%% can match exactly. Deriving the UUID is the server's rule, kept in one place
%% so an agent cannot get it subtly wrong.
%%
%% The digest has to cover the archive and nothing else — see
%% `nh_packbeam:byte_length/1', since a partition is bigger than what was
%% written into it.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_metadata).

-export([from_packbeam/1, describe/2, join_params/1, atomvm_version/0, hex/1]).

%%-----------------------------------------------------------------------------
%% @doc Describe a packbeam held in memory.
%%
%% Hashes only the archive, so passing a whole partition is fine. For a device
%% that would rather not hold the archive at all, `nh_flash' walks and hashes it
%% in chunks and calls `describe/2'.
%% @end
%%-----------------------------------------------------------------------------
-spec from_packbeam(binary()) -> {ok, map()} | {error, term()}.
from_packbeam(Archive) when is_binary(Archive) ->
    case nh_packbeam:byte_length(Archive) of
        {ok, Length} when byte_size(Archive) >= Length ->
            Exact = binary:part(Archive, 0, Length),
            case nh_packbeam:application(Exact) of
                {ok, Application} ->
                    {ok, describe(Application, hex(crypto:hash(sha256, Exact)))};
                {error, _} = Error ->
                    Error
            end;
        {ok, _Length} ->
            {error, truncated_packbeam};
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Build the metadata from an application spec and a digest.
%%
%% Separate from `from_packbeam/1' so that a device which hashed the archive as
%% it read it does not have to hold the archive to describe it.
%% @end
%%-----------------------------------------------------------------------------
-spec describe(map(), binary()) -> map().
describe(Application, Sha256) ->
    #{
        app_name => maps:get(name, Application, undefined),
        app_version => maps:get(vsn, Application, undefined),
        description => maps:get(description, Application, undefined),
        avm_sha256 => Sha256,
        atomvm_version => atomvm_version()
    }.

%%-----------------------------------------------------------------------------
%% @doc The join payload NervesHub expects from an AtomVM device.
%%
%% Keys the device could not determine are left out rather than sent empty. A
%% missing key and a key holding nothing mean the same thing to NervesHub, and
%% leaving it out keeps the agent from asserting something it does not know.
%% @end
%%-----------------------------------------------------------------------------
-spec join_params(map()) -> map().
join_params(Metadata) ->
    Params = #{
        <<"atomvm_app_name">> => maps:get(app_name, Metadata, undefined),
        <<"atomvm_app_version">> => maps:get(app_version, Metadata, undefined),
        <<"atomvm_avm_sha256">> => maps:get(avm_sha256, Metadata, undefined),
        <<"atomvm_version">> => maps:get(atomvm_version, Metadata, undefined)
    },
    Known = maps:filter(fun(_Key, Value) -> Value =/= undefined end, Params),
    Known#{<<"update_tool">> => <<"atomvm">>}.

%%-----------------------------------------------------------------------------
%% @doc The version of the VM this is running on.
%%
%% `undefined' anywhere that is not AtomVM, which is what makes the rest of the
%% library testable off-device.
%% @end
%%-----------------------------------------------------------------------------
-spec atomvm_version() -> binary() | undefined.
atomvm_version() ->
    try erlang:system_info(atomvm_version) of
        Version when is_binary(Version) -> Version;
        Version when is_list(Version) -> list_to_binary(Version);
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%%-----------------------------------------------------------------------------
%% @doc Lower case hex, the encoding NervesHub reads a digest in.
%% @end
%%-----------------------------------------------------------------------------
-spec hex(binary()) -> binary().
hex(Bin) ->
    <<<<(nibble(N))>> || <<N:4>> <= Bin>>.

nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + N - 10.
