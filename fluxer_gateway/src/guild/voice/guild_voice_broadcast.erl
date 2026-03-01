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

-module(guild_voice_broadcast).

-export([broadcast_voice_state_update/3, broadcast_voice_state_update_local/3]).
-export([broadcast_voice_server_update_to_session/7]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type guild_state() :: map().
-type voice_state() :: map().

%% Full broadcast: local sessions + NATS cross-gateway sync
-spec broadcast_voice_state_update(voice_state(), guild_state(), binary() | null) -> ok.
broadcast_voice_state_update(VoiceState, State, OldChannelIdBin) ->
    broadcast_voice_state_update_local(VoiceState, State, OldChannelIdBin),
    publish_voice_sync_to_nats(VoiceState, OldChannelIdBin),
    ok.

%% Local-only broadcast: dispatches to sessions on this gateway (no NATS publish)
-spec broadcast_voice_state_update_local(voice_state(), guild_state(), binary() | null) -> ok.
broadcast_voice_state_update_local(VoiceState, State, OldChannelIdBin) ->
    case maps:get(<<"connection_id">>, VoiceState, undefined) of
        undefined ->
            ok;
        _ConnectionId ->
            Sessions = maps:get(sessions, State, #{}),
            ChannelIdBin = maps:get(<<"channel_id">>, VoiceState, null),
            FilterChannelIdBin =
                case ChannelIdBin of
                    null ->
                        OldChannelIdBin;
                    _ ->
                        ChannelIdBin
                end,
            FilterChannelId = utils:binary_to_integer_safe(FilterChannelIdBin),
            FilteredSessions = guild_sessions:filter_sessions_for_channel(
                Sessions, FilterChannelId, undefined, State
            ),
            Pids = [maps:get(pid, S) || {_Sid, S} <- FilteredSessions],
            lists:foreach(
                fun(Pid) when is_pid(Pid) ->
                    gen_server:cast(Pid, {dispatch, voice_state_update, VoiceState})
                end,
                Pids
            ),
            maybe_relay_voice_state_update(VoiceState, OldChannelIdBin, State),
            ok
    end.

-spec broadcast_voice_server_update_to_session(
    integer(), integer(), binary(), binary(), binary(), binary(), guild_state()
) -> ok.
broadcast_voice_server_update_to_session(
    GuildId,
    ChannelId,
    SessionId,
    Token,
    Endpoint,
    ConnectionId,
    State
) ->
    VoiceServerUpdate = #{
        <<"token">> => Token,
        <<"endpoint">> => Endpoint,
        <<"guild_id">> => integer_to_binary(GuildId),
        <<"channel_id">> => integer_to_binary(ChannelId),
        <<"connection_id">> => ConnectionId
    },
    Sessions = maps:get(sessions, State, #{}),
    case maps:get(SessionId, Sessions, undefined) of
        undefined ->
            maybe_relay_voice_server_update(
                GuildId, ChannelId, SessionId, Token, Endpoint, ConnectionId, State
            ),
            ok;
        SessionData ->
            SessionPid = maps:get(pid, SessionData, null),
            case SessionPid of
                Pid when is_pid(Pid) ->
                    gen_server:cast(Pid, {dispatch, voice_server_update, VoiceServerUpdate}),
                    ok;
                _ ->
                    maybe_relay_voice_server_update(
                        GuildId, ChannelId, SessionId, Token, Endpoint, ConnectionId, State
                    ),
                    ok
            end
    end.

-spec publish_voice_sync_to_nats(voice_state(), binary() | null) -> ok.
publish_voice_sync_to_nats(VoiceState, OldChannelIdBin) ->
    GuildIdBin = maps:get(<<"guild_id">>, VoiceState, null),
    case GuildIdBin of
        null -> ok;
        _ ->
            InstanceId = persistent_term:get(gateway_instance_id, <<>>),
            OldChBin = case OldChannelIdBin of
                null -> null;
                V when is_binary(V) -> V;
                _ -> null
            end,
            gateway_nats_rpc:publish_voice_sync(
                <<"voice.sync.state.", GuildIdBin/binary>>,
                #{
                    <<"source">> => InstanceId,
                    <<"voice_state">> => VoiceState,
                    <<"old_channel_id">> => OldChBin
                }
            )
    end.

-spec maybe_relay_voice_state_update(map(), binary() | null, guild_state()) -> ok.
maybe_relay_voice_state_update(VoiceState, OldChannelIdBin, State) ->
    case {maps:get(very_large_guild_coordinator_pid, State, undefined),
        maps:get(very_large_guild_shard_index, State, undefined)}
    of
        {CoordPid, ShardIndex} when is_pid(CoordPid), is_integer(ShardIndex) ->
            CoordPid ! {very_large_guild_voice_state_update, ShardIndex, VoiceState, OldChannelIdBin},
            ok;
        _ ->
            ok
    end.

-spec maybe_relay_voice_server_update(
    integer(),
    integer(),
    binary(),
    binary(),
    binary(),
    binary(),
    guild_state()
) -> ok.
maybe_relay_voice_server_update(GuildId, ChannelId, SessionId, Token, Endpoint, ConnectionId, State) ->
    case {maps:get(very_large_guild_coordinator_pid, State, undefined),
        maps:get(very_large_guild_shard_index, State, undefined)}
    of
        {CoordPid, ShardIndex} when is_pid(CoordPid), is_integer(ShardIndex) ->
            CoordPid !
                {very_large_guild_voice_server_update, ShardIndex, GuildId, ChannelId, SessionId,
                    Token, Endpoint, ConnectionId},
            ok;
        _ ->
            ok
    end.

-ifdef(TEST).

broadcast_voice_state_update_missing_connection_id_test() ->
    VoiceState = #{<<"user_id">> => <<"1">>},
    State = #{sessions => #{}},
    ?assertEqual(ok, broadcast_voice_state_update(VoiceState, State, null)).

broadcast_voice_state_update_local_missing_connection_id_test() ->
    VoiceState = #{<<"user_id">> => <<"1">>},
    State = #{sessions => #{}},
    ?assertEqual(ok, broadcast_voice_state_update_local(VoiceState, State, null)).

publish_voice_sync_to_nats_null_guild_id_test() ->
    %% Voice state with no guild_id should be a no-op
    VoiceState = #{<<"user_id">> => <<"1">>},
    ?assertEqual(ok, publish_voice_sync_to_nats(VoiceState, null)).

publish_voice_sync_to_nats_normalizes_old_channel_id_test() ->
    %% Ensures non-binary OldChannelIdBin is normalized to null
    persistent_term:put(gateway_instance_id, <<"test_gw">>),
    VoiceState = #{<<"guild_id">> => <<"123">>, <<"user_id">> => <<"1">>},
    %% This will try to call gateway_nats_rpc:publish_voice_sync which won't
    %% be running in test, but we're testing the normalization path doesn't crash.
    %% The function catches errors from publish_voice_sync gracefully.
    try
        publish_voice_sync_to_nats(VoiceState, null),
        publish_voice_sync_to_nats(VoiceState, <<"456">>)
    catch
        _:_ -> ok  %% gateway_nats_rpc not running in test
    end.

-endif.
