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

import fs from 'node:fs';
import {Logger} from '@fluxer/api/src/Logger';
import {SignJWT, importPKCS8} from 'jose';

interface ServiceAccountKey {
	project_id: string;
	client_email: string;
	private_key: string;
	token_uri: string;
}

interface FCMMessage {
	notification?: {title: string; body: string};
	data?: Record<string, string>;
	android?: {priority?: string; notification?: {channel_id?: string; sound?: string}};
}

export class FCMService {
	private serviceAccount: ServiceAccountKey;
	private cachedAccessToken: string | null = null;
	private tokenExpiresAt = 0;

	constructor(serviceAccountKeyPath: string) {
		const raw = fs.readFileSync(serviceAccountKeyPath, 'utf-8');
		this.serviceAccount = JSON.parse(raw) as ServiceAccountKey;
		Logger.info({projectId: this.serviceAccount.project_id}, 'FCM service initialized');
	}

	private async getAccessToken(): Promise<string> {
		if (this.cachedAccessToken && Date.now() < this.tokenExpiresAt) {
			return this.cachedAccessToken;
		}

		const now = Math.floor(Date.now() / 1000);
		const privateKey = await importPKCS8(this.serviceAccount.private_key, 'RS256');

		const jwt = await new SignJWT({scope: 'https://www.googleapis.com/auth/firebase.messaging'})
			.setProtectedHeader({alg: 'RS256'})
			.setIssuer(this.serviceAccount.client_email)
			.setSubject(this.serviceAccount.client_email)
			.setAudience(this.serviceAccount.token_uri)
			.setIssuedAt(now)
			.setExpirationTime(now + 3600)
			.sign(privateKey);

		const response = await fetch(this.serviceAccount.token_uri, {
			method: 'POST',
			headers: {'Content-Type': 'application/x-www-form-urlencoded'},
			body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
		});

		if (!response.ok) {
			const text = await response.text();
			throw new Error(`Failed to get FCM access token: ${response.status} ${text}`);
		}

		const data = (await response.json()) as {access_token: string; expires_in: number};
		this.cachedAccessToken = data.access_token;
		this.tokenExpiresAt = Date.now() + (data.expires_in - 60) * 1000;
		return data.access_token;
	}

	async sendToToken(fcmToken: string, message: FCMMessage): Promise<boolean> {
		try {
			const accessToken = await this.getAccessToken();
			const url = `https://fcm.googleapis.com/v1/projects/${this.serviceAccount.project_id}/messages:send`;

			const response = await fetch(url, {
				method: 'POST',
				headers: {
					Authorization: `Bearer ${accessToken}`,
					'Content-Type': 'application/json',
				},
				body: JSON.stringify({
					message: {
						token: fcmToken,
						...message,
					},
				}),
			});

			if (!response.ok) {
				const text = await response.text();
				Logger.warn({fcmToken: fcmToken.substring(0, 16), status: response.status, error: text}, 'FCM send failed');
				return false;
			}

			return true;
		} catch (error) {
			Logger.error({error}, 'FCM sendToToken error');
			return false;
		}
	}

	async sendToTokens(tokens: Array<string>, message: FCMMessage): Promise<void> {
		await Promise.allSettled(tokens.map((token) => this.sendToToken(token, message)));
	}
}
