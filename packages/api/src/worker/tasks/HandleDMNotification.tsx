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

import {createChannelID, createMessageID, createUserID} from '@fluxer/api/src/BrandedTypes';
import {Config} from '@fluxer/api/src/Config';
import {Logger} from '@fluxer/api/src/Logger';
import {getWorkerDependencies} from '@fluxer/api/src/worker/WorkerContext';
import type {WorkerTaskHandler} from '@fluxer/worker/src/contracts/WorkerTask';
import {z} from 'zod';

const PayloadSchema = z.object({
	channelId: z.string(),
	messageId: z.string(),
	authorId: z.string(),
});

const handleDMNotification: WorkerTaskHandler = async (payload, helpers) => {
	const validated = PayloadSchema.parse(payload);
	helpers.logger.debug({payload: validated}, 'Processing handleDMNotification task');

	if (!Config.fcm.enabled) {
		return;
	}

	const {channelRepository, gatewayService, userRepository, fcmService, pushDeviceRepository} =
		getWorkerDependencies();

	if (!fcmService || !pushDeviceRepository) {
		return;
	}

	const channelId = createChannelID(BigInt(validated.channelId));
	const messageId = createMessageID(BigInt(validated.messageId));
	const authorId = createUserID(BigInt(validated.authorId));

	const channel = await channelRepository.findUnique(channelId);
	if (!channel) {
		Logger.debug({channelId}, 'handleDMNotification: Channel not found, skipping');
		return;
	}

	const message = await channelRepository.getMessage(channelId, messageId);
	if (!message) {
		Logger.debug({messageId}, 'handleDMNotification: Message not found, skipping');
		return;
	}

	const recipientIds = Array.from(channel.recipientIds || []).filter((id) => id !== authorId);
	if (recipientIds.length === 0) {
		return;
	}

	const offlineRecipientIds = [];
	for (const userId of recipientIds) {
		const isOnline = await gatewayService.hasActivePresence(userId);
		if (!isOnline) {
			offlineRecipientIds.push(userId);
		}
	}

	if (offlineRecipientIds.length === 0) {
		return;
	}

	const author = await userRepository.findUnique(authorId);
	const authorName = author?.globalName ?? author?.username ?? 'Someone';

	const deviceMap = await pushDeviceRepository.getBulkPushDevices(offlineRecipientIds);
	const allTokens: Array<string> = [];
	for (const devices of deviceMap.values()) {
		for (const device of devices) {
			allTokens.push(device.fcmToken);
		}
	}

	if (allTokens.length === 0) {
		return;
	}

	const contentPreview = message.content ? message.content.substring(0, 200) : 'Sent a message';

	try {
		await fcmService.sendToTokens(allTokens, {
			notification: {
				title: authorName,
				body: contentPreview,
			},
			data: {
				type: 'dm',
				channel_id: channelId.toString(),
				message_id: messageId.toString(),
				author_id: authorId.toString(),
			},
			android: {
				priority: 'high',
				notification: {
					channel_id: 'dm_messages',
				},
			},
		});
	} catch (error) {
		Logger.error({error, channelId}, 'handleDMNotification: FCM send failed');
	}
};

export default handleDMNotification;
