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

-module(guild_voice_server).
-behaviour(gen_server).

-export([
    start_link/2,
    stop/1,
    lookup/1,
    get_cached_voice_states_list/1,
    fetch_keydb_voice_states/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(REGISTRY_TABLE, guild_voice_registry).
-define(VOICE_STATES_CACHE, guild_voice_states_cache).
-define(SWEEP_INTERVAL_MS, 10000).
-define(GUILD_CALL_TIMEOUT, 10000).

-type voice_state() :: map().
-type voice_state_map() :: #{binary() => voice_state()}.
-type server_state() :: #{
    guild_id := integer(),
    guild_pid := pid(),
    voice_states := voice_state_map(),
    pending_voice_connections := map(),
    recently_disconnected_voice_states := map()
}.

-spec start_link(integer(), pid()) -> {ok, pid()} | {error, term()}.
start_link(GuildId, GuildPid) ->
    gen_server:start_link(?MODULE, #{guild_id => GuildId, guild_pid => GuildPid}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

-spec lookup(integer()) -> {ok, pid()} | {error, not_found}.
lookup(GuildId) ->
    ensure_registry(),
    case ets:lookup(?REGISTRY_TABLE, GuildId) of
        [{_, Pid}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    logger:info("voice_server lookup: guild=~p found dead pid=~p, cleaning", [GuildId, Pid]),
                    ets:delete(?REGISTRY_TABLE, GuildId),
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

-spec init(map()) -> {ok, server_state()}.
init(#{guild_id := GuildId, guild_pid := GuildPid}) ->
    process_flag(trap_exit, true),
    ensure_registry(),
    %% Stop any stale voice_server for this guild to prevent duplicate processes
    ExistingEntry = ets:lookup(?REGISTRY_TABLE, GuildId),
    logger:info(
        "voice_server init: guild=~p self=~p guild_pid=~p existing_ets=~p",
        [GuildId, self(), GuildPid, ExistingEntry]
    ),
    case ExistingEntry of
        [{_, OldPid}] when is_pid(OldPid), OldPid =/= self() ->
            case is_process_alive(OldPid) of
                true ->
                    logger:info(
                        "voice_server replacing stale process ~p for guild ~p (alive=true)",
                        [OldPid, GuildId]
                    ),
                    catch gen_server:stop(OldPid, replaced, 5000);
                false ->
                    logger:info(
                        "voice_server found dead process ~p for guild ~p, cleaning up",
                        [OldPid, GuildId]
                    )
            end;
        _ -> ok
    end,
    ets:insert(?REGISTRY_TABLE, {GuildId, self()}),
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep_pending_joins),
    erlang:send_after(100, self(), fetch_remote_voice_states),
    %% Synchronously fetch active voice states from KeyDB (for failover restoration)
    InitialVoiceStates = fetch_keydb_voice_states(GuildId),
    cache_voice_states(GuildId, InitialVoiceStates),
    {ok, #{
        guild_id => GuildId,
        guild_pid => GuildPid,
        voice_states => InitialVoiceStates,
        pending_voice_connections => #{},
        recently_disconnected_voice_states => #{}
    }}.

-spec handle_call(term(), gen_server:from(), server_state()) ->
    {reply, term(), server_state()}.

handle_call({voice_state_update, Request}, _From, #{guild_id := GuildId} = State) ->
    OldPending = maps:get(pending_voice_connections, State, #{}),
    GuildState = build_guild_state(State),
    case guild_voice:voice_state_update(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            NewState = apply_guild_state(NewGuildState, State),
            NewPending = maps:get(pending_voice_connections, NewState, #{}),
            NewKeys = maps:keys(NewPending) -- maps:keys(OldPending),
            case NewKeys of
                [] -> ok;
                _ ->
                    logger:info(
                        "voice_server created pending: guild=~p new_keys=~p total_pending=~p self=~p",
                        [GuildId, NewKeys, maps:size(NewPending), self()]
                    )
            end,
            sync_new_pending_connections(GuildId, OldPending, NewPending),
            %% Broadcast confirmations for pending connections that were restored
            RemovedKeys = maps:keys(OldPending) -- maps:keys(NewPending),
            lists:foreach(fun(RemovedConnId) ->
                publish_pending_confirmed(GuildId, RemovedConnId)
            end, RemovedKeys),
            {reply, Reply, NewState}
    end;

handle_call({get_voice_state, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:get_voice_state(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({update_member_voice, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:update_member_voice(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({disconnect_voice_user, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:disconnect_voice_user(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({disconnect_voice_user_if_in_channel, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:disconnect_voice_user_if_in_channel(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({disconnect_all_voice_users_in_channel, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:disconnect_all_voice_users_in_channel(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({confirm_voice_connection_from_livekit, Request}, _From, #{guild_id := GuildId} = State) ->
    ConnectionId = maps:get(connection_id, Request, undefined),
    PendingConns = maps:get(pending_voice_connections, State, #{}),
    VoiceStates = maps:get(voice_states, State, #{}),
    logger:info(
        "voice_server confirm: conn=~s pending=~p voice=~p keys=~p self=~p guild=~p",
        [ConnectionId, maps:size(PendingConns), maps:size(VoiceStates), maps:keys(PendingConns), self(), maps:get(guild_id, State, unknown)]
    ),
    GuildState = build_guild_state(State),
    case guild_voice:confirm_voice_connection_from_livekit(Request, GuildState) of
        {reply, #{success := true} = Reply, NewGuildState} ->
            FinalState = apply_guild_state(NewGuildState, State),
            FinalPending = maps:get(pending_voice_connections, FinalState, #{}),
            logger:info(
                "voice_server confirm result: conn=~s reply=~p final_pending=~p final_pending_keys=~p",
                [ConnectionId, Reply, maps:size(FinalPending), maps:keys(FinalPending)]
            ),
            %% Broadcast confirmation to other gateways so they clear their pending
            publish_pending_confirmed(GuildId, ConnectionId),
            {reply, Reply, FinalState};
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({move_member, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:move_member(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({switch_voice_region, Request}, _From, State) ->
    GuildState = build_guild_state(State),
    case guild_voice:switch_voice_region_handler(Request, GuildState) of
        {reply, Reply, NewGuildState} ->
            {reply, Reply, apply_guild_state(NewGuildState, State)}
    end;

handle_call({store_pending_connection, ConnectionId, Metadata}, _From, #{guild_id := GuildId} = State) ->
    {current_stacktrace, Stack} = process_info(self(), current_stacktrace),
    ShortStack = lists:sublist(Stack, 5),
    logger:info(
        "store_pending_connection(call): conn=~s guild=~p existing_keys=~p stack=~p",
        [ConnectionId, GuildId, maps:keys(maps:get(pending_voice_connections, State, #{})), ShortStack]
    ),
    PendingConnections = maps:get(pending_voice_connections, State, #{}),
    NewPendingConnections = maps:put(ConnectionId, Metadata, PendingConnections),
    NewState = maps:put(pending_voice_connections, NewPendingConnections, State),
    publish_pending_connection_sync(GuildId, ConnectionId, Metadata),
    {reply, ok, NewState};

handle_call({get_voice_states_for_channel, ChannelIdBin}, _From, State) ->
    VoiceStates = maps:get(voice_states, State, #{}),
    Filtered = maps:fold(
        fun(ConnId, VS, Acc) ->
            case maps:get(<<"channel_id">>, VS, null) of
                ChannelIdBin ->
                    [#{
                        connection_id => ConnId,
                        user_id => maps:get(<<"user_id">>, VS, null),
                        channel_id => ChannelIdBin
                    } | Acc];
                _ ->
                    Acc
            end
        end,
        [],
        VoiceStates
    ),
    {reply, #{voice_states => Filtered}, State};

handle_call({get_pending_joins_for_channel, ChannelIdBin}, _From, State) ->
    PendingConnections = maps:get(pending_voice_connections, State, #{}),
    ChannelIdInt = binary_to_integer(ChannelIdBin),
    Filtered = maps:fold(
        fun(ConnId, Metadata, Acc) ->
            case maps:get(channel_id, Metadata, undefined) of
                ChannelIdInt ->
                    [#{
                        connection_id => ConnId,
                        user_id => integer_to_binary(maps:get(user_id, Metadata, 0)),
                        token_nonce => maps:get(token_nonce, Metadata, null),
                        expires_at => maps:get(expires_at, Metadata, 0)
                    } | Acc];
                _ ->
                    Acc
            end
        end,
        [],
        PendingConnections
    ),
    {reply, #{pending_joins => Filtered}, State};

handle_call({get_voice_states_list}, _From, State) ->
    VoiceStates = maps:get(voice_states, State, #{}),
    {reply, maps:values(VoiceStates), State};

handle_call({get_voice_states_map}, _From, State) ->
    {reply, maps:get(voice_states, State, #{}), State};

handle_call({set_voice_states, VoiceStates}, _From, #{guild_id := GuildId} = State) ->
    cache_voice_states(GuildId, VoiceStates),
    {reply, ok, maps:put(voice_states, VoiceStates, State)};

handle_call(_, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), server_state()) -> {noreply, server_state()}.

handle_cast({store_pending_connection, ConnectionId, Metadata}, #{guild_id := GuildId} = State) ->
    logger:info(
        "store_pending_connection(cast): conn=~s guild=~p existing_keys=~p",
        [ConnectionId, GuildId, maps:keys(maps:get(pending_voice_connections, State, #{}))]
    ),
    PendingConnections = maps:get(pending_voice_connections, State, #{}),
    NewPendingConnections = maps:put(ConnectionId, Metadata, PendingConnections),
    NewState = maps:put(pending_voice_connections, NewPendingConnections, State),
    publish_pending_connection_sync(GuildId, ConnectionId, Metadata),
    {noreply, NewState};

handle_cast({remote_pending_connection, ConnectionId, Metadata}, State) ->
    logger:info(
        "remote_pending_connection: conn=~s guild=~p existing_keys=~p",
        [ConnectionId, maps:get(guild_id, State, unknown), maps:keys(maps:get(pending_voice_connections, State, #{}))]
    ),
    PendingConnections = maps:get(pending_voice_connections, State, #{}),
    NewPendingConnections = maps:put(ConnectionId, Metadata, PendingConnections),
    NewState = maps:put(pending_voice_connections, NewPendingConnections, State),
    {noreply, NewState};

handle_cast({remote_pending_confirmed, ConnectionId}, State) ->
    PendingConnections = maps:get(pending_voice_connections, State, #{}),
    case maps:is_key(ConnectionId, PendingConnections) of
        true ->
            logger:info(
                "remote_pending_confirmed: removing conn=~s guild=~p",
                [ConnectionId, maps:get(guild_id, State, unknown)]
            ),
            NewPendingConnections = maps:remove(ConnectionId, PendingConnections),
            NewState = maps:put(pending_voice_connections, NewPendingConnections, State),
            %% Also mark confirmed in ETS so sweep skips it if timing race
            catch ets:insert(voice_pending_connections_ets, {{confirmed, ConnectionId}, true}),
            {noreply, NewState};
        false ->
            {noreply, State}
    end;

handle_cast({relay_voice_state_update, VoiceState, OldChannelIdBin}, State) ->
    GuildState = build_guild_state(State),
    State1 = relay_upsert_voice_state(VoiceState, State),
    GuildStateNoRelay = maps:remove(very_large_guild_coordinator_pid, GuildState),
    _ = guild_voice_broadcast:broadcast_voice_state_update_local(
        VoiceState, GuildStateNoRelay, OldChannelIdBin
    ),
    {noreply, State1};

handle_cast({remote_voice_state_update, VoiceState, OldChannelIdBin}, State) ->
    State1 = relay_upsert_voice_state(VoiceState, State),
    GuildState = build_guild_state(State1),
    GuildStateNoRelay = maps:remove(very_large_guild_coordinator_pid, GuildState),
    _ = guild_voice_broadcast:broadcast_voice_state_update_local(
        VoiceState, GuildStateNoRelay, OldChannelIdBin
    ),
    {noreply, State1};

handle_cast(
    {relay_voice_server_update, GuildId, ChannelId, SessionId, Token, Endpoint, ConnectionId},
    State
) ->
    GuildState = build_guild_state(State),
    GuildStateNoRelay = maps:remove(very_large_guild_coordinator_pid, GuildState),
    _ = guild_voice_broadcast:broadcast_voice_server_update_to_session(
        GuildId,
        ChannelId,
        SessionId,
        Token,
        Endpoint,
        ConnectionId,
        GuildStateNoRelay
    ),
    {noreply, State};

handle_cast({cleanup_virtual_access_for_user, UserId}, State) ->
    GuildState = build_guild_state(State),
    NewGuildState = guild_voice_disconnect:cleanup_virtual_channel_access_for_user(
        UserId, GuildState
    ),
    {noreply, apply_guild_state(NewGuildState, State)};

handle_cast(_, State) ->
    {noreply, State}.

-spec handle_info(term(), server_state()) ->
    {noreply, server_state()} | {stop, normal, server_state()}.

handle_info(sweep_pending_joins, State) ->
    ServerPending = maps:get(pending_voice_connections, State, #{}),
    case maps:size(ServerPending) > 0 of
        true ->
            logger:info(
                "sweep_start: server_pending_keys=~p server_pending_count=~p guild=~p",
                [maps:keys(ServerPending), maps:size(ServerPending), maps:get(guild_id, State, unknown)]
            );
        false -> ok
    end,
    GuildState = build_guild_state(State),
    GuildPending = maps:get(pending_voice_connections, GuildState, #{}),
    case maps:size(GuildPending) =/= maps:size(ServerPending) of
        true ->
            logger:info(
                "sweep: guild_state pending DIFFERS from server: guild_keys=~p server_keys=~p",
                [maps:keys(GuildPending), maps:keys(ServerPending)]
            );
        false -> ok
    end,
    NewGuildState = guild_voice_connection:sweep_expired_pending_joins(GuildState),
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep_pending_joins),
    {noreply, apply_guild_state(NewGuildState, State)};

handle_info(fetch_remote_voice_states, #{guild_id := GuildId} = State) ->
    InstanceId = persistent_term:get(gateway_instance_id, <<>>),
    GuildIdBin = integer_to_binary(GuildId),
    %% Request from other live gateways via NATS broadcast
    gateway_nats_rpc:publish_voice_sync(
        <<"voice.sync.request.", GuildIdBin/binary>>,
        #{<<"source">> => InstanceId}
    ),
    %% Also fetch from KeyDB via API RPC (for failover case where peer gateway is dead)
    Self = self(),
    spawn(fun() ->
        Request = #{
            <<"type">> => <<"voice_get_active_states">>,
            <<"guild_id">> => GuildIdBin
        },
        case rpc_client:call(Request) of
            {ok, Data} ->
                VoiceStates = maps:get(<<"voice_states">>, Data, []),
                lists:foreach(fun(VS) ->
                    gen_server:cast(Self, {remote_voice_state_update, VS, null})
                end, VoiceStates);
            {error, Reason} ->
                logger:warning("Failed to fetch active voice states from KeyDB for guild ~p: ~p",
                    [GuildId, Reason])
        end
    end),
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #{guild_pid := GuildPid} = State) when Pid =:= GuildPid ->
    logger:info(
        "Voice server shutting down because guild process exited",
        #{guild_id => maps:get(guild_id, State), reason => Reason}
    ),
    {stop, normal, State};

handle_info(_, State) ->
    {noreply, State}.

-spec terminate(term(), server_state()) -> ok.
terminate(_Reason, #{guild_id := GuildId}) ->
    %% Only clean ETS if we're still the registered process
    %% (prevents race where new voice_server registered before we terminate)
    case catch ets:lookup(?REGISTRY_TABLE, GuildId) of
        [{_, Self}] when Self =:= self() ->
            ets:delete(?REGISTRY_TABLE, GuildId),
            catch ets:delete(?VOICE_STATES_CACHE, GuildId);
        _ ->
            ok
    end,
    ok;
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), server_state(), term()) -> {ok, server_state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec build_guild_state(server_state()) -> map().
build_guild_state(#{guild_pid := GuildPid} = State) ->
    GuildData = fetch_guild_data(GuildPid),
    maps:merge(GuildData, #{
        voice_states => maps:get(voice_states, State, #{}),
        pending_voice_connections => maps:get(pending_voice_connections, State, #{}),
        recently_disconnected_voice_states =>
            maps:get(recently_disconnected_voice_states, State, #{})
    }).

-spec apply_guild_state(map(), server_state()) -> server_state().
apply_guild_state(GuildState, State) ->
    OldPending = maps:get(pending_voice_connections, State, #{}),
    NewPending = maps:get(
        pending_voice_connections,
        GuildState,
        maps:get(pending_voice_connections, State, #{})
    ),
    OldKeys = maps:keys(OldPending),
    NewKeys = maps:keys(NewPending),
    AddedKeys = NewKeys -- OldKeys,
    RemovedKeys = OldKeys -- NewKeys,
    case {AddedKeys, RemovedKeys} of
        {[], []} -> ok;
        _ ->
            {current_stacktrace, Stack} = process_info(self(), current_stacktrace),
            ShortStack = lists:sublist(Stack, 5),
            logger:info(
                "apply_guild_state PENDING CHANGE: old_keys=~p new_keys=~p added=~p removed=~p stack=~p",
                [OldKeys, NewKeys, AddedKeys, RemovedKeys, ShortStack]
            )
    end,
    NewVoiceStates = maps:get(voice_states, GuildState, maps:get(voice_states, State, #{})),
    GuildId = maps:get(guild_id, State),
    cache_voice_states(GuildId, NewVoiceStates),
    State#{
        voice_states => NewVoiceStates,
        pending_voice_connections => NewPending,
        recently_disconnected_voice_states =>
            maps:get(
                recently_disconnected_voice_states,
                GuildState,
                maps:get(recently_disconnected_voice_states, State, #{})
            )
    }.

-spec fetch_guild_data(pid()) -> map().
fetch_guild_data(GuildPid) ->
    try gen_server:call(GuildPid, {get_sessions}, ?GUILD_CALL_TIMEOUT) of
        GuildState when is_map(GuildState) ->
            GuildState;
        _ ->
            #{}
    catch
        exit:{timeout, _} ->
            logger:warning("Voice server timed out fetching guild state", #{}),
            #{};
        exit:{noproc, _} ->
            #{};
        exit:{normal, _} ->
            #{}
    end.

-spec relay_upsert_voice_state(map(), server_state()) -> server_state().
relay_upsert_voice_state(VoiceState, State) when is_map(VoiceState) ->
    ConnectionId = maps:get(<<"connection_id">>, VoiceState, undefined),
    case ConnectionId of
        undefined ->
            State;
        _ ->
            VoiceStates0 = maps:get(voice_states, State, #{}),
            ChannelId = maps:get(<<"channel_id">>, VoiceState, null),
            VoiceStates =
                case ChannelId of
                    null -> maps:remove(ConnectionId, VoiceStates0);
                    _ -> maps:put(ConnectionId, VoiceState, VoiceStates0)
                end,
            GuildId = maps:get(guild_id, State),
            cache_voice_states(GuildId, VoiceStates),
            maps:put(voice_states, VoiceStates, State)
    end;
relay_upsert_voice_state(_, State) ->
    State.

-spec sync_new_pending_connections(integer(), map(), map()) -> ok.
sync_new_pending_connections(GuildId, OldPending, NewPending) ->
    maps:foreach(
        fun(ConnectionId, Metadata) ->
            case maps:is_key(ConnectionId, OldPending) of
                false ->
                    publish_pending_connection_sync(GuildId, ConnectionId, Metadata);
                true ->
                    ok
            end
        end,
        NewPending
    ),
    ok.

-spec publish_pending_connection_sync(integer(), binary(), map()) -> ok.
publish_pending_connection_sync(GuildId, ConnectionId, Metadata) ->
    %% Store in global ETS for cross-gateway confirm fallback
    catch ets:insert(voice_pending_connections_ets, {ConnectionId, Metadata}),
    GuildIdBin = integer_to_binary(GuildId),
    InstanceId = persistent_term:get(gateway_instance_id, <<>>),
    try
        SerializableMetadata = sanitize_for_json(Metadata),
        gateway_nats_rpc:publish_voice_sync(
            <<"voice.sync.pending.", GuildIdBin/binary>>,
            #{
                <<"source">> => InstanceId,
                <<"connection_id">> => ConnectionId,
                <<"metadata">> => SerializableMetadata
            }
        )
    catch
        Class:Reason:Stack ->
            logger:error(
                "Failed to publish pending connection sync: ~p:~p connection_id=~s~n~p",
                [Class, Reason, ConnectionId, Stack]
            ),
            ok
    end.

-spec publish_pending_confirmed(integer(), binary()) -> ok.
publish_pending_confirmed(GuildId, ConnectionId) ->
    GuildIdBin = integer_to_binary(GuildId),
    InstanceId = persistent_term:get(gateway_instance_id, <<>>),
    try
        gateway_nats_rpc:publish_voice_sync(
            <<"voice.sync.confirmed.", GuildIdBin/binary>>,
            #{
                <<"source">> => InstanceId,
                <<"connection_id">> => ConnectionId
            }
        )
    catch
        Class:Reason:Stack ->
            logger:error(
                "Failed to publish pending confirmed sync: ~p:~p connection_id=~s~n~p",
                [Class, Reason, ConnectionId, Stack]
            ),
            ok
    end.

-spec sanitize_for_json(term()) -> term().
sanitize_for_json(V) when is_map(V) ->
    maps:fold(
        fun(K, Val, Acc) ->
            Key = if is_atom(K) -> atom_to_binary(K, utf8); is_binary(K) -> K; true -> K end,
            maps:put(Key, sanitize_for_json(Val), Acc)
        end,
        #{},
        V
    );
sanitize_for_json(V) when is_list(V) ->
    [sanitize_for_json(E) || E <- V];
sanitize_for_json(V) when is_integer(V) -> V;
sanitize_for_json(V) when is_float(V) -> V;
sanitize_for_json(V) when is_binary(V) -> V;
sanitize_for_json(true) -> true;
sanitize_for_json(false) -> false;
sanitize_for_json(null) -> null;
sanitize_for_json(undefined) -> null;
sanitize_for_json(V) when is_atom(V) -> atom_to_binary(V, utf8);
sanitize_for_json(_) -> null.

%% Synchronously fetches active voice states from KeyDB via API RPC.
%% Used during init to restore voice states for failover scenarios.
%% Deduplicates by user_id — keeps only the last entry per user to avoid
%% stale connections appearing as doppelgangers. Deletes stale duplicates
%% from KeyDB so they don't accumulate across failovers.
-spec fetch_keydb_voice_states(integer()) -> voice_state_map().
fetch_keydb_voice_states(GuildId) ->
    GuildIdBin = integer_to_binary(GuildId),
    Request = #{
        <<"type">> => <<"voice_get_active_states">>,
        <<"guild_id">> => GuildIdBin
    },
    case rpc_client:call(Request, 3000) of
        {ok, Data} ->
            RawStates = maps:get(<<"voice_states">>, Data, []),
            AllConnIds = [maps:get(<<"connection_id">>, VS, <<>>) || VS <- RawStates,
                          maps:get(<<"connection_id">>, VS, <<>>) =/= <<>>],
            %% First pass: deduplicate by user_id (last entry wins)
            ByUser = lists:foldl(fun(VS, Acc) ->
                UserId = maps:get(<<"user_id">>, VS, <<>>),
                ConnId = maps:get(<<"connection_id">>, VS, <<>>),
                case {UserId, ConnId} of
                    {<<>>, _} -> Acc;
                    {_, <<>>} -> Acc;
                    _ -> maps:put(UserId, VS, Acc)
                end
            end, #{}, RawStates),
            %% Second pass: re-key by connection_id
            KeptResult = maps:fold(fun(_UserId, VS, Acc) ->
                ConnId = maps:get(<<"connection_id">>, VS, <<>>),
                maps:put(ConnId, VS, Acc)
            end, #{}, ByUser),
            %% Third pass: find stale connection_ids (in KeyDB but not kept after dedup)
            KeptConnIds = maps:keys(KeptResult),
            StaleConnIds = [C || C <- AllConnIds, not lists:member(C, KeptConnIds)],
            case StaleConnIds of
                [] -> ok;
                _ ->
                    logger:info("Cleaning ~p stale voice states from KeyDB for guild ~s",
                                [length(StaleConnIds), GuildIdBin]),
                    spawn(fun() ->
                        DeleteReq = #{
                            <<"type">> => <<"voice_delete_active_states">>,
                            <<"guild_id">> => GuildIdBin,
                            <<"connection_ids">> => StaleConnIds
                        },
                        rpc_client:call(DeleteReq, 5000)
                    end)
            end,
            KeptResult;
        {error, _Reason} ->
            #{}
    end.

%% Reads voice states from ETS cache (lockless, no gen_server call).
%% Used by guild_data to avoid deadlock with the guild process.
-spec get_cached_voice_states_list(integer()) -> [voice_state()].
get_cached_voice_states_list(GuildId) ->
    ensure_registry(),
    case ets:lookup(?VOICE_STATES_CACHE, GuildId) of
        [{_, VoiceStates}] when is_map(VoiceStates) ->
            maps:values(VoiceStates);
        _ ->
            []
    end.

%% Writes current voice states to ETS cache for lockless reads.
-spec cache_voice_states(integer(), voice_state_map()) -> true.
cache_voice_states(GuildId, VoiceStates) ->
    ensure_registry(),
    ets:insert(?VOICE_STATES_CACHE, {GuildId, VoiceStates}).

-spec ensure_registry() -> ok.
ensure_registry() ->
    guild_ets_utils:ensure_table(?REGISTRY_TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    guild_ets_utils:ensure_table(?VOICE_STATES_CACHE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).
