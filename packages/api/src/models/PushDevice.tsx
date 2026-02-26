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
import type {PushDeviceRow} from '@fluxer/api/src/database/types/UserTypes';

export class PushDevice {
	readonly userId: UserID;
	readonly deviceId: string;
	readonly fcmToken: string;
	readonly platform: string | null;
	readonly deviceName: string | null;
	readonly createdAt: Date;
	readonly updatedAt: Date;

	constructor(row: PushDeviceRow) {
		this.userId = row.user_id;
		this.deviceId = row.device_id;
		this.fcmToken = row.fcm_token;
		this.platform = row.platform ?? null;
		this.deviceName = row.device_name ?? null;
		this.createdAt = row.created_at;
		this.updatedAt = row.updated_at;
	}

	toRow(): PushDeviceRow {
		return {
			user_id: this.userId,
			device_id: this.deviceId,
			fcm_token: this.fcmToken,
			platform: this.platform,
			device_name: this.deviceName,
			created_at: this.createdAt,
			updated_at: this.updatedAt,
		};
	}
}
