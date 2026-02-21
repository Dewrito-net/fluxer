/*
 * Copyright (C) 2026 Fluxer Contributors
 *
 * This file is part of Fluxer.
 *
 * Fluxer is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Fluxer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with Fluxer. If not, see <https://www.gnu.org/licenses/>.
 */

import type {IKVProvider} from '@fluxer/kv_client/src/IKVProvider';

interface PendingConnectionData {
	userId: string;
	guildId?: string;
	channelId: string;
	tokenNonce: string;
}

const PENDING_KEY_PREFIX = 'voice:pending_conn';
const CONFIRMED_KEY_PREFIX = 'voice:confirmed_conn';
const PENDING_TTL_SECONDS = 60;
const CONFIRMED_TTL_SECONDS = 3600;

export class VoiceConnectionStore {
	constructor(private kvClient: IKVProvider) {}

	async writePendingConnection(connectionId: string, data: PendingConnectionData): Promise<void> {
		const key = `${PENDING_KEY_PREFIX}:${connectionId}`;
		await this.kvClient.setex(key, PENDING_TTL_SECONDS, JSON.stringify(data));
	}

	async getPendingConnection(connectionId: string): Promise<PendingConnectionData | null> {
		const key = `${PENDING_KEY_PREFIX}:${connectionId}`;
		const raw = await this.kvClient.get(key);
		if (!raw) return null;
		return JSON.parse(raw) as PendingConnectionData;
	}

	async deletePendingConnection(connectionId: string): Promise<void> {
		const key = `${PENDING_KEY_PREFIX}:${connectionId}`;
		await this.kvClient.del(key);
	}

	async writeConfirmedConnection(params: {
		guildId?: string;
		channelId: string;
		connectionId: string;
		userId: string;
	}): Promise<void> {
		const scope = params.guildId ?? 'dm';
		const key = `${CONFIRMED_KEY_PREFIX}:${scope}:${params.channelId}:${params.connectionId}`;
		await this.kvClient.setex(
			key,
			CONFIRMED_TTL_SECONDS,
			JSON.stringify({userId: params.userId, confirmedAt: Date.now()}),
		);
	}

	async isConnectionConfirmed(params: {guildId?: string; channelId: string; connectionId: string}): Promise<boolean> {
		const scope = params.guildId ?? 'dm';
		const key = `${CONFIRMED_KEY_PREFIX}:${scope}:${params.channelId}:${params.connectionId}`;
		const result = await this.kvClient.exists(key);
		return result > 0;
	}

	async deleteConfirmedConnection(params: {
		guildId?: string;
		channelId: string;
		connectionId: string;
	}): Promise<void> {
		const scope = params.guildId ?? 'dm';
		const key = `${CONFIRMED_KEY_PREFIX}:${scope}:${params.channelId}:${params.connectionId}`;
		await this.kvClient.del(key);
	}
}
