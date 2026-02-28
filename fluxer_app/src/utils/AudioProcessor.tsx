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

import {Logger} from '@app/lib/Logger';
import VoiceSettingsStore from '@app/stores/VoiceSettingsStore';
import {loadRnnoise, NoiseGateWorkletNode, RnnoiseWorkletNode} from '@sapphi-red/web-noise-suppressor';
import type {TrackProcessor} from 'livekit-client';
import {Track} from 'livekit-client';

const logger = new Logger('AudioProcessor');

const WORKLET_BASE_PATH = '/audio-worklets';
const RNNOISE_WORKLET_PATH = `${WORKLET_BASE_PATH}/rnnoise/workletProcessor.js`;
const NOISE_GATE_WORKLET_PATH = `${WORKLET_BASE_PATH}/noiseGate/workletProcessor.js`;
const RNNOISE_WASM_PATH = `${WORKLET_BASE_PATH}/rnnoise.wasm`;
const RNNOISE_WASM_SIMD_PATH = `${WORKLET_BASE_PATH}/rnnoise_simd.wasm`;

let activeProcessor: AudioProcessorImpl | null = null;

class AudioProcessorImpl implements TrackProcessor<Track.Kind.Audio> {
	name = 'echowire-audio-processor';
	processedTrack?: MediaStreamTrack;

	private audioContext: AudioContext | null = null;
	private sourceNode: MediaStreamAudioSourceNode | null = null;
	private rnnoiseNode: RnnoiseWorkletNode | null = null;
	private noiseGateNode: NoiseGateWorkletNode | null = null;
	private compressorNode: DynamicsCompressorNode | null = null;
	private destinationNode: MediaStreamAudioDestinationNode | null = null;
	private rawTrack: MediaStreamTrack | null = null;
	private rnnoiseWasmBinary: ArrayBuffer | null = null;
	private workletsRegistered = false;

	async init(opts: {track: MediaStreamTrack; kind: Track.Kind}): Promise<void> {
		this.rawTrack = opts.track;
		await this.buildGraph();
	}

	async restart(opts: {track: MediaStreamTrack; kind: Track.Kind}): Promise<void> {
		this.teardownGraph();
		this.rawTrack = opts.track;
		await this.buildGraph();
	}

	async destroy(): Promise<void> {
		this.teardownGraph();
		if (this.audioContext && this.audioContext.state !== 'closed') {
			try {
				await this.audioContext.close();
			} catch {
				// ignore
			}
		}
		this.audioContext = null;
		this.rnnoiseWasmBinary = null;
		this.workletsRegistered = false;
		activeProcessor = null;
		logger.info('Destroyed');
	}

	async rebuild(): Promise<void> {
		if (!this.rawTrack) return;
		this.teardownGraph();
		await this.buildGraph();
	}

	private async buildGraph(): Promise<void> {
		if (!this.rawTrack) return;

		const advancedNoiseSuppression = VoiceSettingsStore.getAdvancedNoiseSuppression();
		const noiseGateEnabled = VoiceSettingsStore.getNoiseGateEnabled();
		const compressorEnabled = VoiceSettingsStore.getCompressorEnabled();

		if (!advancedNoiseSuppression && !noiseGateEnabled && !compressorEnabled) {
			this.processedTrack = this.rawTrack;
			return;
		}

		try {
			if (!this.audioContext || this.audioContext.state === 'closed') {
				this.audioContext = new AudioContext({sampleRate: 48000});
			}

			if (this.audioContext.state === 'suspended') {
				await this.audioContext.resume();
			}

			const needsRnnoise = advancedNoiseSuppression;
			const needsNoiseGate = noiseGateEnabled;

			if ((needsRnnoise || needsNoiseGate) && !this.workletsRegistered) {
				const registrations: Array<Promise<void>> = [];
				if (needsRnnoise) {
					registrations.push(this.audioContext.audioWorklet.addModule(RNNOISE_WORKLET_PATH));
				}
				if (needsNoiseGate) {
					registrations.push(this.audioContext.audioWorklet.addModule(NOISE_GATE_WORKLET_PATH));
				}
				await Promise.all(registrations);
				this.workletsRegistered = true;
			}

			if (needsRnnoise && !this.rnnoiseWasmBinary) {
				this.rnnoiseWasmBinary = await loadRnnoise({
					url: RNNOISE_WASM_PATH,
					simdUrl: RNNOISE_WASM_SIMD_PATH,
				});
			}

			const stream = new MediaStream([this.rawTrack]);
			this.sourceNode = this.audioContext.createMediaStreamSource(stream);
			this.destinationNode = this.audioContext.createMediaStreamDestination();

			let currentNode: AudioNode = this.sourceNode;

			if (needsRnnoise && this.rnnoiseWasmBinary) {
				this.rnnoiseNode = new RnnoiseWorkletNode(this.audioContext, {
					wasmBinary: this.rnnoiseWasmBinary,
					maxChannels: 1,
				});
				currentNode.connect(this.rnnoiseNode);
				currentNode = this.rnnoiseNode;
				logger.debug('RNNoise node connected');
			}

			if (needsNoiseGate) {
				const threshold = VoiceSettingsStore.getNoiseGateThreshold();
				this.noiseGateNode = new NoiseGateWorkletNode(this.audioContext, {
					openThreshold: threshold,
					closeThreshold: threshold - 10,
					holdMs: 90,
					maxChannels: 1,
				});
				currentNode.connect(this.noiseGateNode);
				currentNode = this.noiseGateNode;
				logger.debug('Noise gate node connected', {threshold});
			}

			if (compressorEnabled) {
				this.compressorNode = this.audioContext.createDynamicsCompressor();
				this.compressorNode.threshold.value = -24;
				this.compressorNode.knee.value = 30;
				this.compressorNode.ratio.value = 4;
				this.compressorNode.attack.value = 0.003;
				this.compressorNode.release.value = 0.25;
				currentNode.connect(this.compressorNode);
				currentNode = this.compressorNode;
				logger.debug('Compressor node connected');
			}

			currentNode.connect(this.destinationNode);
			this.processedTrack = this.destinationNode.stream.getAudioTracks()[0];
			logger.info('Audio processing graph built');
		} catch (error) {
			logger.error('Failed to build audio processing graph', error);
			this.teardownGraph();
			this.processedTrack = this.rawTrack;
		}
	}

	private teardownGraph(): void {
		try {
			this.sourceNode?.disconnect();
		} catch {
			// ignore
		}
		try {
			if (this.rnnoiseNode) {
				this.rnnoiseNode.disconnect();
				this.rnnoiseNode.destroy();
			}
		} catch {
			// ignore
		}
		try {
			this.noiseGateNode?.disconnect();
		} catch {
			// ignore
		}
		try {
			this.compressorNode?.disconnect();
		} catch {
			// ignore
		}
		try {
			this.destinationNode?.disconnect();
		} catch {
			// ignore
		}

		this.sourceNode = null;
		this.rnnoiseNode = null;
		this.noiseGateNode = null;
		this.compressorNode = null;
		this.destinationNode = null;
		this.processedTrack = undefined;
	}
}

export function isAudioProcessingEnabled(): boolean {
	return (
		VoiceSettingsStore.getAdvancedNoiseSuppression() ||
		VoiceSettingsStore.getNoiseGateEnabled() ||
		VoiceSettingsStore.getCompressorEnabled()
	);
}

export function createAudioProcessor(): TrackProcessor<Track.Kind.Audio> {
	if (activeProcessor) {
		void activeProcessor.destroy();
	}
	activeProcessor = new AudioProcessorImpl();
	return activeProcessor;
}

export async function rebuildActiveProcessor(): Promise<void> {
	if (activeProcessor) {
		await activeProcessor.rebuild();
	}
}

export function getActiveProcessor(): TrackProcessor<Track.Kind.Audio> | null {
	return activeProcessor;
}
