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

import {createTestAccount} from '@fluxer/api/src/auth/tests/AuthTestUtils';
import {type ApiTestHarness, createApiTestHarness} from '@fluxer/api/src/test/ApiTestHarness';
import {HTTP_STATUS} from '@fluxer/api/src/test/TestConstants';
import {createBuilder} from '@fluxer/api/src/test/TestRequestBuilder';
import {deleteFCMToken, registerFCMToken} from '@fluxer/api/src/user/tests/UserTestUtils';
import {beforeEach, describe, expect, test} from 'vitest';

describe('FCM Token Lifecycle', () => {
	let harness: ApiTestHarness;

	beforeEach(async () => {
		harness = await createApiTestHarness();
	});

	test('register returns a 32-character hex device id', async () => {
		const account = await createTestAccount(harness);
		const result = await registerFCMToken(harness, account.token, 'test-fcm-token-12345');

		expect(result.device_id).toBeDefined();
		expect(result.device_id).toMatch(/^[a-f0-9]{32}$/);
	});

	test('same token produces the same device id', async () => {
		const account = await createTestAccount(harness);
		const fcmToken = 'deterministic-fcm-token';

		const first = await registerFCMToken(harness, account.token, fcmToken);
		const second = await registerFCMToken(harness, account.token, fcmToken);

		expect(first.device_id).toBe(second.device_id);
	});

	test('different tokens produce different device ids', async () => {
		const account = await createTestAccount(harness);

		const first = await registerFCMToken(harness, account.token, 'fcm-token-aaa');
		const second = await registerFCMToken(harness, account.token, 'fcm-token-bbb');

		expect(first.device_id).not.toBe(second.device_id);
	});

	test('register accepts optional platform and device_name', async () => {
		const account = await createTestAccount(harness);
		const result = await registerFCMToken(harness, account.token, 'fcm-token-with-metadata', {
			platform: 'android',
			deviceName: 'Pixel 9',
		});

		expect(result.device_id).toMatch(/^[a-f0-9]{32}$/);
	});

	test('delete token succeeds', async () => {
		const account = await createTestAccount(harness);
		const fcmToken = 'fcm-token-to-delete';

		await registerFCMToken(harness, account.token, fcmToken);
		await deleteFCMToken(harness, account.token, fcmToken);
	});

	test('register rejects empty fcm_token', async () => {
		const account = await createTestAccount(harness);

		await createBuilder(harness, account.token)
			.post('/users/@me/fcm/tokens')
			.body({fcm_token: ''})
			.expect(HTTP_STATUS.BAD_REQUEST)
			.execute();
	});

	test('register rejects missing fcm_token', async () => {
		const account = await createTestAccount(harness);

		await createBuilder(harness, account.token)
			.post('/users/@me/fcm/tokens')
			.body({})
			.expect(HTTP_STATUS.BAD_REQUEST)
			.execute();
	});

	test('register requires authentication', async () => {
		await createBuilder(harness, '')
			.post('/users/@me/fcm/tokens')
			.body({fcm_token: 'some-token'})
			.expect(HTTP_STATUS.UNAUTHORIZED)
			.execute();
	});

	test('delete requires authentication', async () => {
		await createBuilder(harness, '')
			.delete('/users/@me/fcm/tokens')
			.body({fcm_token: 'some-token'})
			.expect(HTTP_STATUS.UNAUTHORIZED)
			.execute();
	});
});
