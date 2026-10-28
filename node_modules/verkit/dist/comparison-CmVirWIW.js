//#region src/version/constants.ts
const SEMVER_SPEC_VERSION = "2.0.0";
const INCREMENT_TYPES = [
	"major",
	"premajor",
	"minor",
	"preminor",
	"patch",
	"prepatch",
	"prerelease",
	"release"
];
const TRUNCATION_TYPES = [
	"major",
	"premajor",
	"minor",
	"preminor",
	"patch",
	"prepatch",
	"prerelease"
];
//#endregion
//#region src/version/patterns.ts
const LETTER_DASH_NUMBER = "[a-zA-Z0-9-]";
const NUMERIC_IDENTIFIER = String.raw`0|[1-9]\d*`;
const NUMERIC_IDENTIFIER_LOOSE = String.raw`\d+`;
const NON_NUMERIC_IDENTIFIER = String.raw`\d*[a-zA-Z-]${LETTER_DASH_NUMBER}*`;
const MAIN_VERSION = String.raw`(${NUMERIC_IDENTIFIER})\.(${NUMERIC_IDENTIFIER})\.(${NUMERIC_IDENTIFIER})`;
const MAIN_VERSION_LOOSE = String.raw`(${NUMERIC_IDENTIFIER_LOOSE})\.(${NUMERIC_IDENTIFIER_LOOSE})\.(${NUMERIC_IDENTIFIER_LOOSE})`;
const PRERELEASE_IDENTIFIER = `(?:${NON_NUMERIC_IDENTIFIER}|${NUMERIC_IDENTIFIER})`;
const PRERELEASE_IDENTIFIER_LOOSE = `(?:${NON_NUMERIC_IDENTIFIER}|${NUMERIC_IDENTIFIER_LOOSE})`;
const PRERELEASE = String.raw`(?:-(${PRERELEASE_IDENTIFIER}(?:\.${PRERELEASE_IDENTIFIER})*))`;
const PRERELEASE_LOOSE = String.raw`(?:-?(${PRERELEASE_IDENTIFIER_LOOSE}(?:\.${PRERELEASE_IDENTIFIER_LOOSE})*))`;
const BUILD_IDENTIFIER = `${LETTER_DASH_NUMBER}+`;
const BUILD = String.raw`(?:\+(${BUILD_IDENTIFIER}(?:\.${BUILD_IDENTIFIER})*))`;
const FULL_PLAIN = `v?${MAIN_VERSION}${PRERELEASE}?${BUILD}?`;
const LOOSE_PLAIN = String.raw`[v=\s]*${MAIN_VERSION_LOOSE}${PRERELEASE_LOOSE}?${BUILD}?`;
const GREATER_LESS_THAN = "((?:<|>)?=?)";
const XRANGE_IDENTIFIER = String.raw`${NUMERIC_IDENTIFIER}|x|X|\*`;
const XRANGE_IDENTIFIER_LOOSE = String.raw`${NUMERIC_IDENTIFIER_LOOSE}|x|X|\*`;
const XRANGE_PLAIN = String.raw`[v=\s]*(${XRANGE_IDENTIFIER})(?:\.(${XRANGE_IDENTIFIER})(?:\.(${XRANGE_IDENTIFIER})(?:${PRERELEASE})?${BUILD}?)?)?`;
const XRANGE_PLAIN_LOOSE = String.raw`[v=\s]*(${XRANGE_IDENTIFIER_LOOSE})(?:\.(${XRANGE_IDENTIFIER_LOOSE})(?:\.(${XRANGE_IDENTIFIER_LOOSE})(?:${PRERELEASE_LOOSE})?${BUILD}?)?)?`;
const LONE_TILDE = "(?:~>?)";
const LONE_CARET = String.raw`(?:\^)`;
const COERCE_PLAIN = String.raw`(^|[^\d])(\d{1,${16}})(?:\.(\d{1,${16}}))?(?:\.(\d{1,${16}}))?`;
const COERCE = String.raw`${COERCE_PLAIN}(?:$|[^\d])`;
const COERCE_FULL = String.raw`${COERCE_PLAIN}(?:${PRERELEASE})?(?:${BUILD})?(?:$|[^\d])`;
function makeSafeRegexSource(source) {
	const replacements = [
		[String.raw`\s`, 1],
		[String.raw`\d`, 256],
		[LETTER_DASH_NUMBER, 250]
	];
	for (const [token, maximum] of replacements) source = source.split(`${token}*`).join(`${token}{0,${maximum}}`).split(`${token}+`).join(`${token}{1,${maximum}}`);
	return source;
}
function safeRegex(source, flags) {
	return new RegExp(makeSafeRegexSource(source), flags);
}
//#endregion
//#region src/version/parse.ts
const FULL = safeRegex(`^${FULL_PLAIN}$`);
const LOOSE = safeRegex(`^${LOOSE_PLAIN}$`);
const NUMERIC$1 = /^\d+$/;
function formatComparableVersion(version) {
	const base = `${version.major}.${version.minor}.${version.patch}`;
	return version.prerelease?.length ? `${base}-${version.prerelease.join(".")}` : base;
}
function formatFullVersion(version) {
	const comparable = formatComparableVersion(version);
	return version.build?.length ? `${comparable}+${version.build.join(".")}` : comparable;
}
function parse(version, options = {}) {
	if (typeof version !== "string") return version;
	if (version.length > 256) throw new TypeError(`Version exceeds the maximum length of 256 characters`);
	const match = version.trim().match(options.loose ? LOOSE : FULL);
	if (!match) throw new TypeError(`Invalid version syntax: ${version}`);
	const major = Number(match[1]);
	const minor = Number(match[2]);
	const patch = Number(match[3]);
	if (major > Number.MAX_SAFE_INTEGER || major < 0) throw new TypeError(`Invalid major version: ${match[1]}`);
	if (minor > Number.MAX_SAFE_INTEGER || minor < 0) throw new TypeError(`Invalid minor version: ${match[2]}`);
	if (patch > Number.MAX_SAFE_INTEGER || patch < 0) throw new TypeError(`Invalid patch version: ${match[3]}`);
	const prerelease = match[4] ? match[4].split(".").map((identifier) => {
		if (NUMERIC$1.test(identifier)) {
			const numeric = Number(identifier);
			if (numeric >= 0 && numeric < Number.MAX_SAFE_INTEGER) return numeric;
		}
		return identifier;
	}) : void 0;
	return {
		build: match[5]?.split("."),
		major,
		minor,
		patch,
		prerelease
	};
}
function tryParse(version, options = {}) {
	try {
		return parse(version, options);
	} catch {
		return null;
	}
}
//#endregion
//#region src/version/identifiers.ts
const NUMERIC = /^\d+$/;
function compareIdentifiers(left, right) {
	if (typeof left === "number" && typeof right === "number") return left === right ? 0 : left < right ? -1 : 1;
	const leftNumeric = NUMERIC.test(String(left));
	const rightNumeric = NUMERIC.test(String(right));
	const normalizedLeft = leftNumeric ? Number(left) : left;
	const normalizedRight = rightNumeric ? Number(right) : right;
	return normalizedLeft === normalizedRight ? 0 : leftNumeric && !rightNumeric ? -1 : rightNumeric && !leftNumeric ? 1 : normalizedLeft < normalizedRight ? -1 : 1;
}
function compareIdentifiersReversed(left, right) {
	return compareIdentifiers(right, left);
}
//#endregion
//#region src/version/comparison.ts
function compareMainParsed(left, right) {
	return left.major === right.major ? left.minor === right.minor ? left.patch === right.patch ? 0 : left.patch < right.patch ? -1 : 1 : left.minor < right.minor ? -1 : 1 : left.major < right.major ? -1 : 1;
}
function comparePrereleaseParsed(left, right) {
	const leftPrerelease = left.prerelease;
	const rightPrerelease = right.prerelease;
	if (leftPrerelease?.length && !rightPrerelease?.length) return -1;
	if (!leftPrerelease?.length && rightPrerelease?.length) return 1;
	if (!leftPrerelease?.length && !rightPrerelease?.length) return 0;
	for (let index = 0;; index++) {
		const leftIdentifier = leftPrerelease?.[index];
		const rightIdentifier = rightPrerelease?.[index];
		if (leftIdentifier === void 0 && rightIdentifier === void 0) return 0;
		if (rightIdentifier === void 0) return 1;
		if (leftIdentifier === void 0) return -1;
		if (leftIdentifier !== rightIdentifier) return compareIdentifiers(leftIdentifier, rightIdentifier);
	}
}
function compareParsed(left, right) {
	return compareMainParsed(left, right) || comparePrereleaseParsed(left, right);
}
function compareBuildParsed(left, right) {
	const precedence = compareParsed(left, right);
	if (precedence !== 0) return precedence;
	for (let index = 0;; index++) {
		const leftIdentifier = left.build?.[index];
		const rightIdentifier = right.build?.[index];
		if (leftIdentifier === void 0 && rightIdentifier === void 0) return 0;
		if (rightIdentifier === void 0) return 1;
		if (leftIdentifier === void 0) return -1;
		if (leftIdentifier !== rightIdentifier) return compareIdentifiers(leftIdentifier, rightIdentifier);
	}
}
function compare(left, right, options = {}) {
	return compareParsed(parse(left, options), parse(right, options));
}
function compareReversed(left, right, options = {}) {
	return compare(right, left, options);
}
function compareMain(left, right, options = {}) {
	return compareMainParsed(parse(left, options), parse(right, options));
}
function comparePrerelease(left, right, options = {}) {
	return comparePrereleaseParsed(parse(left, options), parse(right, options));
}
function compareBuild(left, right, options = {}) {
	return compareBuildParsed(parse(left, options), parse(right, options));
}
function compareWithOperator(left, operator, right, options = {}) {
	if (operator === "===") return left === right;
	if (operator === "!==") return left !== right;
	const comparison = compare(left, right, options);
	switch (operator) {
		case "":
		case "=":
		case "==": return comparison === 0;
		case "!=": return comparison !== 0;
		case ">": return comparison > 0;
		case ">=": return comparison >= 0;
		case "<": return comparison < 0;
		case "<=": return comparison <= 0;
		default: throw new TypeError(`Invalid operator: ${operator}`);
	}
}
function isEqual(left, right, options = {}) {
	return compare(left, right, options) === 0;
}
function isNotEqual(left, right, options = {}) {
	return compare(left, right, options) !== 0;
}
function isGreaterThan(left, right, options = {}) {
	return compare(left, right, options) > 0;
}
function isGreaterThanOrEqual(left, right, options = {}) {
	return compare(left, right, options) >= 0;
}
function isLessThan(left, right, options = {}) {
	return compare(left, right, options) < 0;
}
function isLessThanOrEqual(left, right, options = {}) {
	return compare(left, right, options) <= 0;
}
function sort(versions, options = {}) {
	return [...versions].sort((left, right) => compareBuild(left, right, options));
}
function sortReversed(versions, options = {}) {
	return [...versions].sort((left, right) => compareBuild(right, left, options));
}
//#endregion
export { LOOSE_PLAIN as A, BUILD as C, GREATER_LESS_THAN as D, FULL_PLAIN as E, safeRegex as F, INCREMENT_TYPES as I, SEMVER_SPEC_VERSION as L, PRERELEASE_LOOSE as M, XRANGE_PLAIN as N, LONE_CARET as O, XRANGE_PLAIN_LOOSE as P, TRUNCATION_TYPES as R, tryParse as S, COERCE_FULL as T, compareIdentifiers as _, compareParsed as a, formatFullVersion as b, compareWithOperator as c, isGreaterThanOrEqual as d, isLessThan as f, sortReversed as g, sort as h, compareMainParsed as i, PRERELEASE as j, LONE_TILDE as k, isEqual as l, isNotEqual as m, compareBuild as n, comparePrerelease as o, isLessThanOrEqual as p, compareMain as r, compareReversed as s, compare as t, isGreaterThan as u, compareIdentifiersReversed as v, COERCE as w, parse as x, formatComparableVersion as y };
