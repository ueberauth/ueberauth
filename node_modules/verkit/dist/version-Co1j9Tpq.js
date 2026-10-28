import { F as safeRegex, M as PRERELEASE_LOOSE, R as TRUNCATION_TYPES, S as tryParse, T as COERCE_FULL, _ as compareIdentifiers, a as compareParsed, b as formatFullVersion, i as compareMainParsed, j as PRERELEASE, w as COERCE, x as parse, y as formatComparableVersion } from "./comparison-CmVirWIW.js";
//#region src/version/operations.ts
const COERCE_EXACT = safeRegex(COERCE);
const COERCE_FULL_EXACT = safeRegex(COERCE_FULL);
const PRERELEASE_EXACT = safeRegex(`^${PRERELEASE}$`);
const PRERELEASE_LOOSE_EXACT = safeRegex(`^${PRERELEASE_LOOSE}$`);
function isValid(version, options = {}) {
	return tryParse(version, options) !== null;
}
function isPrerelease(version, options = {}) {
	const parsed = tryParse(version, options);
	if (!parsed) return null;
	return !!parsed.prerelease?.length;
}
function isStable(version, options = {}) {
	const parsed = tryParse(version, options);
	if (!parsed) return null;
	return !parsed.prerelease?.length;
}
function normalizeFull(version, options = {}) {
	const parsed = tryParse(version, options);
	return parsed ? formatFullVersion(parsed) : null;
}
function normalize(version, options = {}) {
	const parsed = tryParse(version, options);
	return parsed ? formatComparableVersion(parsed) : null;
}
function clean(version, options = {}) {
	if (typeof version !== "string") return normalize(version, options);
	return normalize(version.trim().replace(/^[=v]+/, ""), options);
}
function coerce(value, options = {}) {
	if (typeof value === "object") return value;
	const input = typeof value === "number" ? String(value) : value;
	let match = null;
	if (options.rtl) {
		const source = options.includePrerelease ? COERCE_FULL : COERCE;
		const expression = safeRegex(source, "g");
		let next;
		while ((next = expression.exec(input)) && (!match || match.index + match[0].length !== input.length)) {
			if (!match || next.index + next[0].length !== match.index + match[0].length) match = next;
			expression.lastIndex = next.index + next[1].length + next[2].length;
		}
	} else match = (options.includePrerelease ? COERCE_FULL_EXACT : COERCE_EXACT).exec(input);
	if (!match) return null;
	const major = match[2];
	const minor = match[3] || "0";
	const patch = match[4] || "0";
	const prerelease = options.includePrerelease && match[5] ? `-${match[5]}` : "";
	const build = options.includePrerelease && match[6] ? `+${match[6]}` : "";
	return tryParse(`${major}.${minor}.${patch}${prerelease}${build}`, options);
}
function isPrereleasePrefix(prerelease, identifier) {
	const identifiers = identifier.split(".");
	return identifiers.length <= prerelease.length && identifiers.every((part, index) => compareIdentifiers(prerelease[index], part) === 0);
}
function incrementPrerelease(version, identifier, identifierBase) {
	const base = Number(identifierBase) ? 1 : 0;
	let prerelease = version.prerelease;
	if (prerelease?.length) {
		let foundNumeric = false;
		for (let index = prerelease.length - 1; index >= 0; index--) if (typeof prerelease[index] === "number") {
			prerelease[index] = Number(prerelease[index]) + 1;
			foundNumeric = true;
			break;
		}
		if (!foundNumeric) {
			if (identifier === prerelease.join(".") && identifierBase === false) throw new Error("invalid increment argument: identifier already exists");
			prerelease.push(base);
		}
	} else {
		prerelease = [base];
		version.prerelease = prerelease;
	}
	if (!identifier) return;
	const reset = identifierBase === false ? [identifier] : [identifier, base];
	if (isPrereleasePrefix(prerelease, identifier)) {
		const next = prerelease[identifier.split(".").length];
		if (Number.isNaN(Number(next))) version.prerelease = reset;
	} else version.prerelease = reset;
}
function incrementMutable(version, release, identifier, identifierBase) {
	switch (release) {
		case "premajor":
			version.prerelease = void 0;
			version.patch = 0;
			version.minor = 0;
			version.major++;
			incrementPrerelease(version, identifier, identifierBase);
			break;
		case "preminor":
			version.prerelease = void 0;
			version.patch = 0;
			version.minor++;
			incrementPrerelease(version, identifier, identifierBase);
			break;
		case "prepatch":
			version.prerelease = void 0;
			incrementMutable(version, "patch", identifier, identifierBase);
			incrementPrerelease(version, identifier, identifierBase);
			break;
		case "prerelease":
			if (!version.prerelease?.length) incrementMutable(version, "patch", identifier, identifierBase);
			incrementPrerelease(version, identifier, identifierBase);
			break;
		case "release":
			if (!version.prerelease?.length) throw new Error(`version ${formatFullVersion(version)} is not a prerelease`);
			version.prerelease = void 0;
			break;
		case "major":
			if (version.minor !== 0 || version.patch !== 0 || !version.prerelease?.length) version.major++;
			version.minor = 0;
			version.patch = 0;
			version.prerelease = void 0;
			break;
		case "minor":
			if (version.patch !== 0 || !version.prerelease?.length) version.minor++;
			version.patch = 0;
			version.prerelease = void 0;
			break;
		case "patch":
			if (!version.prerelease?.length) version.patch++;
			version.prerelease = void 0;
			break;
		/* v8 ignore next */
		case "pre":
			incrementPrerelease(version, identifier, identifierBase);
			break;
		default: throw new Error(`invalid increment argument: ${release}`);
	}
}
function incrementParsedVersion(parsed, release, identifier, identifierBase, loose = false) {
	if (release.startsWith("pre")) {
		if (!identifier && identifierBase === false) throw new Error("invalid increment argument: identifier is empty");
		if (identifier) {
			const expression = loose ? PRERELEASE_LOOSE_EXACT : PRERELEASE_EXACT;
			const match = `-${identifier}`.match(expression);
			if (!match || match[1] !== identifier) throw new Error(`invalid identifier: ${identifier}`);
		}
	}
	const mutable = {
		build: parsed.build ? [...parsed.build] : void 0,
		major: parsed.major,
		minor: parsed.minor,
		patch: parsed.patch,
		prerelease: parsed.prerelease ? [...parsed.prerelease] : void 0
	};
	incrementMutable(mutable, release, identifier, identifierBase);
	return formatComparableVersion(mutable);
}
function increment(version, release, options = {}) {
	try {
		return incrementParsedVersion(parse(version, options), release, options.identifier, options.identifierBase, options.loose);
	} catch {
		return null;
	}
}
function truncate(version, truncation, options = {}) {
	if (!TRUNCATION_TYPES.includes(truncation)) return null;
	const parsed = tryParse(version, options);
	if (!parsed) return null;
	if (truncation.startsWith("pre")) return formatComparableVersion(parsed);
	return formatComparableVersion({
		major: parsed.major,
		minor: truncation === "major" ? 0 : parsed.minor,
		patch: truncation === "major" || truncation === "minor" ? 0 : parsed.patch
	});
}
function difference(left, right) {
	const leftVersion = parse(left);
	const rightVersion = parse(right);
	const comparison = compareParsed(leftVersion, rightVersion);
	if (comparison === 0) return null;
	const high = comparison > 0 ? leftVersion : rightVersion;
	const low = comparison > 0 ? rightVersion : leftVersion;
	const highHasPrerelease = high.prerelease?.length;
	if (low.prerelease?.length && !highHasPrerelease) {
		if (low.patch === 0 && low.minor === 0) return "major";
		if (compareMainParsed(low, high) === 0) return low.minor !== 0 && low.patch === 0 ? "minor" : "patch";
	}
	const prefix = highHasPrerelease ? "pre" : "";
	if (leftVersion.major !== rightVersion.major) return `${prefix}major`;
	if (leftVersion.minor !== rightVersion.minor) return `${prefix}minor`;
	if (leftVersion.patch !== rightVersion.patch) return `${prefix}patch`;
	return "prerelease";
}
function getMajor(version, options = {}) {
	return parse(version, options).major;
}
function getMinor(version, options = {}) {
	return parse(version, options).minor;
}
function getPatch(version, options = {}) {
	return parse(version, options).patch;
}
function getPrerelease(version, options = {}) {
	const parsed = tryParse(version, options);
	return parsed ? [...parsed.prerelease || []] : null;
}
function getBuild(version, options = {}) {
	const parsed = tryParse(version, options);
	return parsed ? [...parsed.build || []] : null;
}
//#endregion
export { getMajor as a, getPrerelease as c, isStable as d, isValid as f, truncate as h, getBuild as i, increment as l, normalizeFull as m, coerce as n, getMinor as o, normalize as p, difference as r, getPatch as s, clean as t, isPrerelease as u };
