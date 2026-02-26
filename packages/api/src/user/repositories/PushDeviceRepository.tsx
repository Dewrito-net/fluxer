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

import type {UserID} from '@fluxer/api/src/BrandedTypes';
import {deleteOneOrMany, fetchMany, upsertOne} from '@fluxer/api/src/database/Cassandra';
import type {PushDeviceRow} from '@fluxer/api/src/database/types/UserTypes';
import {PushDevice} from '@fluxer/api/src/models/PushDevice';
import {PushDevices} from '@fluxer/api/src/Tables';

const FETCH_PUSH_DEVICES_CQL = PushDevices.selectCql({
	where: PushDevices.where.eq('user_id'),
});

const FETCH_BULK_PUSH_DEVICES_CQL = PushDevices.selectCql({
	where: PushDevices.where.in('user_id', 'user_ids'),
});

export class PushDeviceRepository {
	async listPushDevices(userId: UserID): Promise<Array<PushDevice>> {
		const rows = await fetchMany<PushDeviceRow>(FETCH_PUSH_DEVICES_CQL, {user_id: userId});
		return rows.map((row) => new PushDevice(row));
	}

	async upsertPushDevice(data: PushDeviceRow): Promise<PushDevice> {
		await upsertOne(PushDevices.upsertAll(data));
		return new PushDevice(data);
	}

	async deletePushDevice(userId: UserID, deviceId: string): Promise<void> {
		await deleteOneOrMany(PushDevices.deleteByPk({user_id: userId, device_id: deviceId}));
	}

	async getBulkPushDevices(userIds: Array<UserID>): Promise<Map<UserID, Array<PushDevice>>> {
		if (userIds.length === 0) return new Map();

		const rows = await fetchMany<PushDeviceRow>(FETCH_BULK_PUSH_DEVICES_CQL, {user_ids: userIds});

		const map = new Map<UserID, Array<PushDevice>>();
		for (const row of rows) {
			const device = new PushDevice(row);
			const existing = map.get(row.user_id) ?? [];
			existing.push(device);
			map.set(row.user_id, existing);
		}
		return map;
	}

	async deleteAllPushDevices(userId: UserID): Promise<void> {
		await deleteOneOrMany(
			PushDevices.delete({where: PushDevices.where.eq('user_id')}).bind({user_id: userId}),
		);
	}
}
