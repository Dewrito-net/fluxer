%% Copyright (C) 2026 Fluxer Contributors
%%
%% This file is part of Fluxer.
%%
%% Fluxer is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% Fluxer is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
%% GNU Affero General Public License for more details.
%%
%% You should have received a copy of the GNU Affero General Public License
%% along with Fluxer. If not, see <https://www.gnu.org/licenses/>.

-module(gateway_nats_rpc).
-behaviour(gen_server).

-export([start_link/0, get_connection/0, publish_voice_sync/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_MAX_HANDLERS, 1024).
-define(RECONNECT_DELAY_MS, 2000).
-define(RPC_SUBJECT_PREFIX, <<"rpc.gateway.">>).
-define(RPC_SUBJECT_WILDCARD, <<"rpc.gateway.>">>).
-define(QUEUE_GROUP, <<"gateway">>).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_connection() -> {ok, nats:conn() | undefined} | {error, term()}.
get_connection() ->
    gen_server:call(?MODULE, get_connection).

-spec init([]) -> {ok, map()}.
init([]) ->
    process_flag(trap_exit, true),
    InstanceId = base64:encode(crypto:strong_rand_bytes(12)),
    persistent_term:put(gateway_instance_id, InstanceId),
    self() ! connect,
    {ok, #{
        conn => undefined,
        sub => undefined,
        voice_sync_sub => undefined,
        handler_count => 0,
        max_handlers => max_handlers(),
        monitor_ref => undefined
    }}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(get_connection, _From, #{conn := Conn} = State) ->
    {reply, {ok, Conn}, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(connect, State) ->
    {noreply, do_connect(State)};
handle_info({Conn, ready}, #{conn := Conn} = State) ->
    {noreply, do_subscribe(State)};
handle_info({Conn, closed}, #{conn := Conn} = State) ->
    logger:warning("Gateway NATS RPC connection closed, reconnecting"),
    {noreply, schedule_reconnect(State#{conn => undefined, sub => undefined, voice_sync_sub => undefined, monitor_ref => undefined})};
handle_info({Conn, {error, Reason}}, #{conn := Conn} = State) ->
    logger:warning("Gateway NATS RPC connection error: ~p, reconnecting", [Reason]),
    {noreply, schedule_reconnect(State#{conn => undefined, sub => undefined, voice_sync_sub => undefined, monitor_ref => undefined})};
handle_info({Conn, _Sid, {msg, <<"voice.sync.", _/binary>> = Subject, Payload, _MsgOpts}},
            #{conn := Conn} = State) ->
    spawn(fun() -> handle_voice_sync(Subject, Payload) end),
    {noreply, State};
handle_info({Conn, _Sid, {msg, Subject, Payload, MsgOpts}},
            #{conn := Conn, handler_count := HandlerCount, max_handlers := MaxHandlers} = State) ->
    case maps:get(reply_to, MsgOpts, undefined) of
        undefined ->
            {noreply, State};
        ReplyTo ->
            case HandlerCount >= MaxHandlers of
                true ->
                    ErrorResponse = iolist_to_binary(json:encode(#{
                        <<"ok">> => false,
                        <<"error">> => <<"overloaded">>
                    })),
                    nats:pub(Conn, ReplyTo, ErrorResponse),
                    {noreply, State};
                false ->
                    Parent = self(),
                    spawn(fun() ->
                        try
                            handle_rpc_request(Conn, Subject, Payload, ReplyTo)
                        after
                            Parent ! {handler_done, self()}
                        end
                    end),
                    {noreply, State#{handler_count => HandlerCount + 1}}
            end
    end;
handle_info({handler_done, _Pid}, #{handler_count := HandlerCount} = State) when HandlerCount > 0 ->
    {noreply, State#{handler_count => HandlerCount - 1}};
handle_info({handler_done, _Pid}, State) ->
    {noreply, State};
handle_info({'DOWN', MRef, process, Conn, Reason}, #{conn := Conn, monitor_ref := MRef} = State) ->
    logger:warning("Gateway NATS RPC connection process died: ~p, reconnecting", [Reason]),
    {noreply, schedule_reconnect(State#{conn => undefined, sub => undefined, voice_sync_sub => undefined, monitor_ref => undefined})};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{conn := Conn}) when Conn =/= undefined ->
    catch nats:disconnect(Conn),
    logger:info("Gateway NATS RPC subscriber stopped"),
    ok;
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), map(), term()) -> {ok, map()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec do_connect(map()) -> map().
do_connect(State) ->
    NatsUrl = fluxer_gateway_env:get(nats_core_url),
    AuthToken = fluxer_gateway_env:get(nats_auth_token),
    case parse_nats_url(NatsUrl) of
        {ok, Host, Port} ->
            Opts = build_connect_opts(AuthToken),
            case nats:connect(Host, Port, Opts) of
                {ok, Conn} ->
                    MRef = nats:monitor(Conn),
                    logger:info("Gateway NATS RPC connected to ~s:~p", [Host, Port]),
                    State#{conn => Conn, monitor_ref => MRef};
                {error, Reason} ->
                    logger:error("Gateway NATS RPC failed to connect: ~p", [Reason]),
                    schedule_reconnect(State)
            end;
        {error, Reason} ->
            logger:error("Gateway NATS RPC failed to parse URL: ~p", [Reason]),
            schedule_reconnect(State)
    end.

-spec do_subscribe(map()) -> map().
do_subscribe(#{conn := Conn} = State) when Conn =/= undefined ->
    State1 = case nats:sub(Conn, ?RPC_SUBJECT_WILDCARD, #{queue_group => ?QUEUE_GROUP}) of
        {ok, Sid} ->
            logger:info("Gateway NATS RPC subscribed to ~s with queue group ~s",
                        [?RPC_SUBJECT_WILDCARD, ?QUEUE_GROUP]),
            State#{sub => Sid};
        {error, Reason} ->
            logger:error("Gateway NATS RPC failed to subscribe: ~p", [Reason]),
            State
    end,
    case nats:sub(Conn, <<"voice.sync.>">>) of
        {ok, VoiceSyncSid} ->
            logger:info("Gateway NATS voice sync subscribed to voice.sync.>"),
            State1#{voice_sync_sub => VoiceSyncSid};
        {error, VoiceSyncReason} ->
            logger:error("Gateway NATS voice sync failed to subscribe: ~p", [VoiceSyncReason]),
            State1
    end;
do_subscribe(State) ->
    State.

-spec handle_rpc_request(nats:conn(), binary(), binary(), binary()) -> ok.
handle_rpc_request(Conn, Subject, Payload, ReplyTo) ->
    Method = strip_rpc_prefix(Subject),
    Response = execute_rpc_method(Method, Payload),
    ResponseBin = iolist_to_binary(json:encode(Response)),
    nats:pub(Conn, ReplyTo, ResponseBin),
    ok.

-spec strip_rpc_prefix(binary()) -> binary().
strip_rpc_prefix(<<"rpc.gateway.", Method/binary>>) ->
    Method;
strip_rpc_prefix(Subject) ->
    Subject.

-spec execute_rpc_method(binary(), binary()) -> map().
execute_rpc_method(Method, PayloadBin) ->
    try
        Params = json:decode(PayloadBin),
        Result = gateway_rpc_router:execute(Method, Params),
        #{<<"ok">> => true, <<"result">> => Result}
    catch
        throw:{error, Message} ->
            #{<<"ok">> => false, <<"error">> => error_binary(Message)};
        exit:timeout ->
            #{<<"ok">> => false, <<"error">> => <<"timeout">>};
        exit:{timeout, _} ->
            #{<<"ok">> => false, <<"error">> => <<"timeout">>};
        Class:Reason ->
            logger:error(
                "Gateway NATS RPC method execution failed. method=~ts class=~p reason=~p",
                [Method, Class, Reason]
            ),
            #{<<"ok">> => false, <<"error">> => <<"internal_error">>}
    end.

-spec publish_voice_sync(binary(), map()) -> ok.
publish_voice_sync(Subject, Payload) ->
    case get_connection() of
        {ok, Conn} when Conn =/= undefined ->
            PayloadBin = iolist_to_binary(json:encode(Payload)),
            nats:pub(Conn, Subject, PayloadBin),
            ok;
        _ ->
            ok
    end.

-spec handle_voice_sync(binary(), binary()) -> ok.
handle_voice_sync(<<"voice.sync.state.", GuildIdBin/binary>>, Payload) ->
    Data = json:decode(Payload),
    SourceId = maps:get(<<"source">>, Data, <<>>),
    MyId = persistent_term:get(gateway_instance_id, <<>>),
    case SourceId =:= MyId of
        true -> ok;
        false ->
            GuildId = binary_to_integer(GuildIdBin),
            VoiceState = maps:get(<<"voice_state">>, Data),
            OldChannelId = maps:get(<<"old_channel_id">>, Data, null),
            case guild_voice_server:lookup(GuildId) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {remote_voice_state_update, VoiceState, OldChannelId});
                _ ->
                    ok
            end
    end;
handle_voice_sync(<<"voice.sync.request.", GuildIdBin/binary>>, Payload) ->
    Data = json:decode(Payload),
    SourceId = maps:get(<<"source">>, Data, <<>>),
    MyId = persistent_term:get(gateway_instance_id, <<>>),
    case SourceId =:= MyId of
        true -> ok;
        false ->
            GuildId = binary_to_integer(GuildIdBin),
            case guild_voice_server:lookup(GuildId) of
                {ok, Pid} ->
                    try gen_server:call(Pid, {get_voice_states_list}, 5000) of
                        VoiceStates when is_list(VoiceStates) ->
                            lists:foreach(fun(VS) ->
                                Subject = <<"voice.sync.state.", GuildIdBin/binary>>,
                                publish_voice_sync(Subject, #{
                                    <<"source">> => MyId,
                                    <<"voice_state">> => VS,
                                    <<"old_channel_id">> => null
                                })
                            end, VoiceStates);
                        _ -> ok
                    catch _:_ -> ok
                    end;
                _ -> ok
            end
    end;
handle_voice_sync(<<"voice.sync.pending.", GuildIdBin/binary>>, Payload) ->
    Data = json:decode(Payload),
    SourceId = maps:get(<<"source">>, Data, <<>>),
    MyId = persistent_term:get(gateway_instance_id, <<>>),
    case SourceId =:= MyId of
        true -> ok;
        false ->
            GuildId = binary_to_integer(GuildIdBin),
            ConnectionId = maps:get(<<"connection_id">>, Data),
            MetadataJson = maps:get(<<"metadata">>, Data, #{}),
            Metadata = deserialize_pending_metadata(MetadataJson),
            %% Always store in global ETS so confirm RPCs can find it
            %% even if no voice server exists on this gateway
            catch ets:insert(voice_pending_connections_ets, {ConnectionId, Metadata}),
            case guild_voice_server:lookup(GuildId) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {remote_pending_connection, ConnectionId, Metadata});
                _ ->
                    ok
            end
    end;
handle_voice_sync(<<"voice.sync.confirmed.", GuildIdBin/binary>>, Payload) ->
    Data = json:decode(Payload),
    SourceId = maps:get(<<"source">>, Data, <<>>),
    MyId = persistent_term:get(gateway_instance_id, <<>>),
    case SourceId =:= MyId of
        true -> ok;  %% Ignore own confirmations
        false ->
            GuildId = binary_to_integer(GuildIdBin),
            ConnectionId = maps:get(<<"connection_id">>, Data),
            %% Mark confirmed in local ETS
            catch ets:insert(voice_pending_connections_ets, {{confirmed, ConnectionId}, true}),
            %% Remove from local voice_server's pending
            case guild_voice_server:lookup(GuildId) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {remote_pending_confirmed, ConnectionId});
                _ ->
                    ok
            end
    end;
handle_voice_sync(_, _) -> ok.

-spec deserialize_pending_metadata(map()) -> map().
deserialize_pending_metadata(JsonMap) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = binary_to_atom(K, utf8),
            Val = case Key of
                user_id when is_binary(V) -> binary_to_integer(V);
                channel_id when is_binary(V) -> binary_to_integer(V);
                guild_id when is_binary(V) -> binary_to_integer(V);
                session_id when is_binary(V) -> V;
                expires_at when is_integer(V) -> V;
                token_nonce when is_binary(V) -> V;
                _ -> V
            end,
            maps:put(Key, Val, Acc)
        end,
        #{},
        JsonMap
    ).

-spec error_binary(term()) -> binary().
error_binary(Value) when is_binary(Value) ->
    Value;
error_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
error_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
error_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

-spec parse_nats_url(term()) -> {ok, string(), inet:port_number()} | {error, term()}.
parse_nats_url(Url) when is_list(Url) ->
    parse_nats_url(list_to_binary(Url));
parse_nats_url(<<"nats://", Rest/binary>>) ->
    parse_host_port(Rest);
parse_nats_url(<<"tls://", Rest/binary>>) ->
    parse_host_port(Rest);
parse_nats_url(Url) when is_binary(Url) ->
    parse_host_port(Url);
parse_nats_url(_) ->
    {error, invalid_nats_url}.

-spec parse_host_port(binary()) -> {ok, string(), inet:port_number()} | {error, term()}.
parse_host_port(HostPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host, PortBin] ->
            try
                Port = binary_to_integer(PortBin),
                {ok, binary_to_list(Host), Port}
            catch
                _:_ -> {error, invalid_port}
            end;
        [Host] ->
            {ok, binary_to_list(Host), 4222}
    end.

-spec build_connect_opts(term()) -> map().
build_connect_opts(AuthToken) when is_binary(AuthToken), byte_size(AuthToken) > 0 ->
    #{auth_token => AuthToken, buffer_size => 0};
build_connect_opts(AuthToken) when is_list(AuthToken) ->
    case AuthToken of
        "" -> #{buffer_size => 0};
        _ -> #{auth_token => list_to_binary(AuthToken), buffer_size => 0}
    end;
build_connect_opts(_) ->
    #{buffer_size => 0}.

-spec schedule_reconnect(map()) -> map().
schedule_reconnect(State) ->
    erlang:send_after(?RECONNECT_DELAY_MS, self(), connect),
    State.

-spec max_handlers() -> pos_integer().
max_handlers() ->
    case fluxer_gateway_env:get(gateway_http_rpc_max_concurrency) of
        Value when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?DEFAULT_MAX_HANDLERS
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_nats_url_test() ->
    ?assertEqual({ok, "127.0.0.1", 4222}, parse_nats_url(<<"nats://127.0.0.1:4222">>)),
    ?assertEqual({ok, "localhost", 4222}, parse_nats_url(<<"nats://localhost:4222">>)),
    ?assertEqual({ok, "localhost", 4222}, parse_nats_url(<<"nats://localhost">>)),
    ?assertEqual({ok, "127.0.0.1", 4222}, parse_nats_url("nats://127.0.0.1:4222")),
    ?assertEqual({error, invalid_nats_url}, parse_nats_url(undefined)).

handle_voice_sync_ignores_own_messages_test() ->
    %% Set up a known instance ID
    persistent_term:put(gateway_instance_id, <<"test_instance_abc">>),
    %% Message from ourselves should be ignored (returns ok, no side effects)
    Payload = iolist_to_binary(json:encode(#{
        <<"source">> => <<"test_instance_abc">>,
        <<"voice_state">> => #{<<"user_id">> => <<"123">>},
        <<"old_channel_id">> => null
    })),
    ?assertEqual(ok, handle_voice_sync(<<"voice.sync.state.999">>, Payload)).

handle_voice_sync_ignores_own_requests_test() ->
    persistent_term:put(gateway_instance_id, <<"test_instance_abc">>),
    Payload = iolist_to_binary(json:encode(#{
        <<"source">> => <<"test_instance_abc">>
    })),
    ?assertEqual(ok, handle_voice_sync(<<"voice.sync.request.999">>, Payload)).

handle_voice_sync_unknown_subject_test() ->
    ?assertEqual(ok, handle_voice_sync(<<"voice.sync.unknown.123">>, <<"{}">>)).

handle_voice_sync_state_guild_not_found_test() ->
    %% Remote message for a guild not loaded locally should be silently ignored
    persistent_term:put(gateway_instance_id, <<"local_gw">>),
    Payload = iolist_to_binary(json:encode(#{
        <<"source">> => <<"remote_gw">>,
        <<"voice_state">> => #{
            <<"connection_id">> => <<"conn1">>,
            <<"user_id">> => <<"456">>,
            <<"channel_id">> => <<"789">>,
            <<"guild_id">> => <<"99999">>
        },
        <<"old_channel_id">> => null
    })),
    %% Guild 99999 won't be in the registry, so lookup returns {error, not_found}
    ?assertEqual(ok, handle_voice_sync(<<"voice.sync.state.99999">>, Payload)).

-endif.
