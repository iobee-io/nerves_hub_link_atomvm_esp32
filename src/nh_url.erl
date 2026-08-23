%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Work out the socket URL to connect to.
%%
%% A device needs one URL and there is only one it can sensibly want, so most
%% configurations should not have to write it out. Everything here has a
%% default:
%%
%% ```
%% #{}                                     wss://devices.nervescloud.com/device-socket/websocket?vsn=2.0.0
%% #{host => "nh.example.com"}             wss://nh.example.com/device-socket/websocket?vsn=2.0.0
%% #{url => "ws://192.168.1.10:4000"}      ws://192.168.1.10:4000/device-socket/websocket?vsn=2.0.0
%% '''
%%
%% Anything already there is kept, so a URL written out in full is passed
%% through untouched and an unusual mount point survives.
%%
%% == Which path ==
%%
%% NervesHub serves the device socket at two paths and which one to use depends
%% on how the device authenticates.
%%
%% A device with a client certificate connects to the device endpoint, where the
%% socket is at `/socket'. A device with a shared secret goes through the web
%% endpoint instead, where `/socket' is already taken by the browser socket and
%% the device socket is at `/device-socket'.
%%
%% Neither path implies an authentication method by itself -- the server reads
%% the certificate if the connection presents one and the headers otherwise --
%% so this only picks the path the matching endpoint is listening on.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_url).

-export([resolve/1, default_host/0]).

-define(DEFAULT_HOST, <<"devices.nervescloud.com">>).
%% Encrypted unless the configuration says otherwise: a shared secret is a
%% credential, and over ws:// it goes out in headers anyone on the path can read.
-define(DEFAULT_SCHEME, <<"wss://">>).
-define(SHARED_SECRET_PATH, <<"/device-socket/websocket">>).
-define(CERTIFICATE_PATH, <<"/socket/websocket">>).
%% The Phoenix wire format. Without it the server falls back to v1, which
%% brackets messages differently and does not match what `nh_channel' writes.
-define(QUERY, <<"vsn=2.0.0">>).

-spec default_host() -> binary().
default_host() -> ?DEFAULT_HOST.

%%-----------------------------------------------------------------------------
%% @doc Build the URL an agent config asks for.
%% @end
%%-----------------------------------------------------------------------------
-spec resolve(map()) -> {ok, binary()} | {error, term()}.
resolve(Config) ->
    case base(Config) of
        {ok, Base} -> {ok, build(Base, path(Config))};
        {error, _} = Error -> Error
    end.

%% `url' and `host' are the same field at different levels of detail, so giving
%% both is a contradiction rather than something to silently resolve.
base(#{url := _, host := _}) ->
    {error, {conflicting_config, [url, host]}};
base(#{url := Url}) ->
    non_empty(url, Url);
base(#{host := Host}) ->
    non_empty(host, Host);
base(_Config) ->
    {ok, ?DEFAULT_HOST}.

non_empty(Key, Value) ->
    case text(Value) of
        <<>> -> {error, {empty_config, Key}};
        Text -> {ok, Text}
    end.

%% A certificate reaches the device endpoint, a shared secret goes through the
%% web endpoint. A config carrying both presents the certificate, which is what
%% the server authenticates on, so follow it.
path(#{client_cert := _}) -> ?CERTIFICATE_PATH;
path(_Config) -> ?SHARED_SECRET_PATH.

build(Base, DefaultPath) ->
    %% Query first: a query string can contain slashes, and splitting on those
    %% before removing it would take part of it for the path.
    {BeforeQuery, Query} = split(Base, <<"?">>),
    {Origin, Path} = origin(scheme(BeforeQuery)),

    <<Origin/binary, (or_default(Path, DefaultPath))/binary, "?",
        (or_default(Query, ?QUERY))/binary>>.

scheme(Url) ->
    case binary:match(Url, <<"://">>) of
        nomatch -> <<?DEFAULT_SCHEME/binary, Url/binary>>;
        _Found -> Url
    end.

origin(Url) ->
    {Scheme, Rest} = split(Url, <<"://">>),

    case split(Rest, <<"/">>) of
        {Authority, <<>>} -> {<<Scheme/binary, "://", Authority/binary>>, <<>>};
        {Authority, Path} -> {<<Scheme/binary, "://", Authority/binary>>, <<"/", Path/binary>>}
    end.

split(Subject, Pattern) ->
    case binary:split(Subject, Pattern) of
        [Before] -> {Before, <<>>};
        [Before, After] -> {Before, After}
    end.

%% A bare `/' is a host with no path written out, not a path.
or_default(<<>>, Default) -> Default;
or_default(<<"/">>, Default) -> Default;
or_default(Value, _Default) -> Value.

text(Value) when is_binary(Value) -> Value;
text(Value) when is_list(Value) -> list_to_binary(Value).
