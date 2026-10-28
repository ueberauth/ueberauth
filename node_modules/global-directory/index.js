import process from 'node:process';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import ini from 'ini';

const isWindows = process.platform === 'win32';

const untildify = pathWithTilde => pathWithTilde && pathWithTilde.startsWith('~') ? path.join(os.homedir(), pathWithTilde.slice(1)) : pathWithTilde;

const readConfigValue = (filePath, key) => {
	if (!filePath) {
		return;
	}

	try {
		return ini.parse(fs.readFileSync(filePath, 'utf8'))[key];
	} catch {}
};

const getEnvironmentNpmConfigValue = key => {
	const normalizedKey = `npm_config_${key.replaceAll('-', '_')}`.toLowerCase();
	const environmentKey = Object.keys(process.env).find(name => name.toLowerCase() === normalizedKey);
	return environmentKey ? process.env[environmentKey] : undefined;
};

const getGlobalNpmrc = () => {
	if (isWindows && process.env.APPDATA) {
		// Hardcoded contents of `c:\Program Files\nodejs\node_modules\npm\npmrc`
		return path.join(process.env.APPDATA, '/npm/etc/npmrc');
	}

	// Homebrew special case: `$(brew --prefix)/lib/node_modules/npm/npmrc`
	if (process.execPath.includes('/Cellar/node')) {
		const homebrewPrefix = process.execPath.slice(0, process.execPath.indexOf('/Cellar/node'));
		return path.join(homebrewPrefix, '/lib/node_modules/npm/npmrc');
	}

	if (process.execPath.endsWith('/bin/node')) {
		const installDir = path.dirname(path.dirname(process.execPath));
		return path.join(installDir, '/etc/npmrc');
	}
};

const getDefaultNpmPrefix = () => {
	if (isWindows) {
		const {APPDATA} = process.env;
		// `c:\node\node.exe` → `prefix=c:\node\`
		return APPDATA ? path.join(APPDATA, 'npm') : path.dirname(process.execPath);
	}

	// Homebrew: `/opt/homebrew/Cellar/node/21.0.0/bin/node` → `/opt/homebrew`
	if (process.execPath.includes('/Cellar/node')) {
		return process.execPath.slice(0, process.execPath.indexOf('/Cellar/node'));
	}

	// `/usr/local/bin/node` → `prefix=/usr/local`
	return path.dirname(path.dirname(process.execPath));
};

const getNpmPrefix = () => {
	const environmentPrefix = getEnvironmentNpmConfigValue('prefix');
	if (environmentPrefix !== undefined) {
		return environmentPrefix;
	}

	const homePrefix = readConfigValue(path.join(os.homedir(), '.npmrc'), 'prefix');
	if (homePrefix !== undefined) {
		return homePrefix;
	}

	if (process.env.PREFIX) {
		return process.env.PREFIX;
	}

	const globalPrefix = readConfigValue(getGlobalNpmrc(), 'prefix');
	if (globalPrefix !== undefined) {
		return globalPrefix;
	}

	return getDefaultNpmPrefix();
};

const npmPrefix = path.resolve(untildify(getNpmPrefix()));

const getYarnHomeDirectory = () => {
	if (process.getuid?.() === 0 && !process.env.FAKEROOTKEY) {
		return '/usr/local/share';
	}

	return os.homedir();
};

const getYarnDataDirectory = () => {
	if (isWindows) {
		return process.env.LOCALAPPDATA
			? path.join(process.env.LOCALAPPDATA, 'Yarn/Data')
			: path.join(os.homedir(), '.config/yarn');
	}

	if (process.env.XDG_DATA_HOME) {
		return path.join(process.env.XDG_DATA_HOME, 'yarn');
	}

	return path.join(getYarnHomeDirectory(), '.config/yarn');
};

const getYarnBinPrefix = () => {
	if (process.env.PREFIX) {
		return process.env.PREFIX;
	}

	if (isWindows) {
		return process.env.LOCALAPPDATA
			? path.join(process.env.LOCALAPPDATA, 'Yarn')
			: path.join(os.homedir(), '.yarn');
	}

	return `${process.env.DESTDIR ?? ''}/usr/local`;
};

const globalDirectory = {};

globalDirectory.npm = {};
globalDirectory.npm.prefix = npmPrefix;
globalDirectory.npm.packages = path.join(npmPrefix, isWindows ? 'node_modules' : 'lib/node_modules');
globalDirectory.npm.binaries = isWindows ? npmPrefix : path.join(npmPrefix, 'bin');

const yarnDataDir = path.resolve(getYarnDataDirectory());
globalDirectory.yarn = {};
globalDirectory.yarn.prefix = yarnDataDir;
globalDirectory.yarn.packages = path.join(yarnDataDir, 'global/node_modules');
globalDirectory.yarn.binaries = path.join(path.resolve(getYarnBinPrefix()), 'bin');

const getPnpmDataDirectory = () => {
	if (process.env.PNPM_HOME) {
		return process.env.PNPM_HOME;
	}

	if (process.env.XDG_DATA_HOME) {
		return path.join(process.env.XDG_DATA_HOME, 'pnpm');
	}

	if (process.platform === 'darwin') {
		return path.join(os.homedir(), 'Library/pnpm');
	}

	if (!isWindows) {
		return path.join(os.homedir(), '.local/share/pnpm');
	}

	if (process.env.LOCALAPPDATA) {
		return path.join(process.env.LOCALAPPDATA, 'pnpm');
	}

	return path.join(os.homedir(), '.pnpm');
};

const getPnpmConfigFilePath = () => {
	if (process.env.XDG_CONFIG_HOME) {
		return path.join(process.env.XDG_CONFIG_HOME, 'pnpm', 'rc');
	}

	if (isWindows) {
		const localConfigHome = process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local');
		return path.join(localConfigHome, 'pnpm', 'config', 'rc');
	}

	if (process.platform === 'darwin') {
		return path.join(os.homedir(), 'Library', 'Preferences', 'pnpm', 'rc');
	}

	return path.join(os.homedir(), '.config', 'pnpm', 'rc');
};

const getPnpmConfigValue = key => {
	const environmentValue = getEnvironmentNpmConfigValue(key);
	if (environmentValue !== undefined) {
		return environmentValue;
	}

	const pnpmGlobalValue = readConfigValue(getPnpmConfigFilePath(), key);
	if (pnpmGlobalValue !== undefined) {
		return pnpmGlobalValue;
	}

	const homeValue = readConfigValue(path.join(os.homedir(), '.npmrc'), key);
	if (homeValue !== undefined) {
		return homeValue;
	}

	const globalValue = readConfigValue(getGlobalNpmrc(), key);
	if (globalValue !== undefined) {
		return globalValue;
	}
};

const pnpmDataDir = path.resolve(getPnpmDataDirectory());
const pnpmGlobalDir = getPnpmConfigValue('global-dir');
const pnpmGlobalBinDir = getPnpmConfigValue('global-bin-dir');
const resolvedPnpmGlobalDir = path.resolve(untildify(pnpmGlobalDir ?? path.join(pnpmDataDir, 'global')));
const resolvedPnpmGlobalBinDir = path.resolve(untildify(pnpmGlobalBinDir ?? pnpmDataDir));
globalDirectory.pnpm = {};
globalDirectory.pnpm.prefix = pnpmDataDir;
globalDirectory.pnpm.packages = path.join(resolvedPnpmGlobalDir, '5/node_modules');
globalDirectory.pnpm.binaries = resolvedPnpmGlobalBinDir;

export default globalDirectory;
