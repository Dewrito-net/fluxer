import fs from 'node:fs';
import path from 'node:path';
import {BUILD_CHANNEL} from '@electron/common/BuildChannel';
import {showWindow} from '@electron/main/Window';
import {app, Menu, nativeImage, Tray} from 'electron';
import log from 'electron-log';

let tray: Tray | null = null;

function resolveIconPath(): string | null {
	const isLinux = process.platform === 'linux';
	const iconName = isLinux ? '256x256.png' : '256x256.png';

	const resourcePath = path.join(process.resourcesPath, iconName);
	if (fs.existsSync(resourcePath)) {
		return resourcePath;
	}

	const exeDirPath = path.join(path.dirname(app.getPath('exe')), iconName);
	if (fs.existsSync(exeDirPath)) {
		return exeDirPath;
	}

	return null;
}

export function createTray(): Tray | null {
	if (tray) return tray;

	const iconPath = resolveIconPath();
	if (!iconPath) {
		log.warn('[Tray] No icon found, skipping tray creation');
		return null;
	}

	const icon = nativeImage.createFromPath(iconPath);
	const resized = icon.resize({width: 24, height: 24});

	const isCanary = BUILD_CHANNEL === 'canary';
	const appName = isCanary ? 'Echowire Canary' : 'Echowire';

	tray = new Tray(resized);
	tray.setToolTip(appName);

	const contextMenu = Menu.buildFromTemplate([
		{
			label: `Show ${appName}`,
			click: () => showWindow(),
		},
		{type: 'separator'},
		{
			label: 'Quit',
			click: () => {
				app.quit();
			},
		},
	]);

	tray.setContextMenu(contextMenu);

	tray.on('click', () => {
		showWindow();
	});

	log.info('[Tray] Created system tray icon');
	return tray;
}

export function destroyTray(): void {
	if (tray) {
		tray.destroy();
		tray = null;
	}
}
