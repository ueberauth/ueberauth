import { A as LOOSE_PLAIN, C as BUILD, D as GREATER_LESS_THAN, F as safeRegex, N as XRANGE_PLAIN, O as LONE_CARET, P as XRANGE_PLAIN_LOOSE, S as tryParse, a as compareParsed, h as sort, k as LONE_TILDE, x as parse, y as formatComparableVersion } from "./comparison-CmVirWIW.js";
import { a as testParsedComparator, n as parsedComparatorsIntersect, o as formatComparator, r as testComparatorSet, s as parseComparator, t as comparatorAllowsPrerelease } from "./set-BGFWKKE8.js";
//#region src/range/parse.ts
function formatRange(range) {
	return range.sets.map((set) => set.map(formatComparator).join(" ")).join("||");
}
const BUILD_STRIP = new RegExp(BUILD, "g");
const BUILD_SAFE = safeRegex(BUILD);
const STRICT_HYPHEN = safeRegex(String.raw`^\s*(${XRANGE_PLAIN})\s+-\s+(${XRANGE_PLAIN})\s*$`);
const LOOSE_HYPHEN = safeRegex(String.raw`^\s*(${XRANGE_PLAIN_LOOSE})\s+-\s+(${XRANGE_PLAIN_LOOSE})\s*$`);
const COMPARATOR_TRIM = safeRegex(String.raw`(\s*)${GREATER_LESS_THAN}\s*(${LOOSE_PLAIN}|${XRANGE_PLAIN})`, "g");
const TILDE_TRIM = safeRegex(String.raw`(\s*)${LONE_TILDE}\s+`, "g");
const CARET_TRIM = safeRegex(String.raw`(\s*)${LONE_CARET}\s+`, "g");
const STRICT_TILDE = safeRegex(`^${LONE_TILDE}${XRANGE_PLAIN}$`);
const LOOSE_TILDE = safeRegex(`^${LONE_TILDE}${XRANGE_PLAIN_LOOSE}$`);
const STRICT_CARET = safeRegex(`^${LONE_CARET}${XRANGE_PLAIN}$`);
const LOOSE_CARET = safeRegex(`^${LONE_CARET}${XRANGE_PLAIN_LOOSE}$`);
const STRICT_XRANGE = safeRegex(String.raw`^${GREATER_LESS_THAN}\s*${XRANGE_PLAIN}$`);
const LOOSE_XRANGE = safeRegex(String.raw`^${GREATER_LESS_THAN}\s*${XRANGE_PLAIN_LOOSE}$`);
const STAR = safeRegex(String.raw`(<|>)?=?\s*\*`);
const GTE_ZERO = /^\s*>=\s*0\.0\.0\s*$/;
const GTE_ZERO_PRERELEASE = /^\s*>=\s*0\.0\.0-0\s*$/;
const LOOSE_COMPARATOR = safeRegex(String.raw`^${GREATER_LESS_THAN}\s*(${LOOSE_PLAIN})$|^$`);
function isWildcard(value) {
	return !value || String(value).toLowerCase() === "x" || String(value) === "*";
}
function hasInvalidWildcardOrder(major, minor, patch) {
	return isWildcard(major) && !isWildcard(minor) || isWildcard(minor) && Boolean(patch) && !isWildcard(patch);
}
function replaceTilde(comparator, options) {
	const expression = options.loose ? LOOSE_TILDE : STRICT_TILDE;
	const lowerPrerelease = options.includePrerelease ? "-0" : "";
	return comparator.replace(expression, (_match, major, minor, patch, prerelease) => {
		if (isWildcard(major)) return "";
		if (isWildcard(minor)) return `>=${major}.0.0${lowerPrerelease} <${Number(major) + 1}.0.0-0`;
		if (isWildcard(patch)) return `>=${major}.${minor}.0${lowerPrerelease} <${major}.${Number(minor) + 1}.0-0`;
		return prerelease ? `>=${major}.${minor}.${patch}-${prerelease} <${major}.${Number(minor) + 1}.0-0` : `>=${major}.${minor}.${patch} <${major}.${Number(minor) + 1}.0-0`;
	});
}
function replaceTildes(comparator, options) {
	return comparator.trim().split(/\s+/).map((part) => replaceTilde(part, options)).join(" ");
}
function replaceCaret(comparator, options) {
	const expression = options.loose ? LOOSE_CARET : STRICT_CARET;
	const lowerPrerelease = options.includePrerelease ? "-0" : "";
	return comparator.replace(expression, (_match, major, minor, patch, prerelease) => {
		if (isWildcard(major)) return "";
		if (isWildcard(minor)) return `>=${major}.0.0${lowerPrerelease} <${Number(major) + 1}.0.0-0`;
		if (isWildcard(patch)) return major === "0" ? `>=${major}.${minor}.0${lowerPrerelease} <${major}.${Number(minor) + 1}.0-0` : `>=${major}.${minor}.0${lowerPrerelease} <${Number(major) + 1}.0.0-0`;
		if (prerelease) return major === "0" ? minor === "0" ? `>=${major}.${minor}.${patch}-${prerelease} <${major}.${minor}.${Number(patch) + 1}-0` : `>=${major}.${minor}.${patch}-${prerelease} <${major}.${Number(minor) + 1}.0-0` : `>=${major}.${minor}.${patch}-${prerelease} <${Number(major) + 1}.0.0-0`;
		return major === "0" ? minor === "0" ? `>=${major}.${minor}.${patch} <${major}.${minor}.${Number(patch) + 1}-0` : `>=${major}.${minor}.${patch} <${major}.${Number(minor) + 1}.0-0` : `>=${major}.${minor}.${patch} <${Number(major) + 1}.0.0-0`;
	});
}
function replaceCarets(comparator, options) {
	return comparator.trim().split(/\s+/).map((part) => replaceCaret(part, options)).join(" ");
}
function replaceXRange(comparator, options) {
	const expression = options.loose ? LOOSE_XRANGE : STRICT_XRANGE;
	return comparator.trim().replace(expression, (match, rawOperator, rawMajor, rawMinor, rawPatch) => {
		let operator = rawOperator;
		let major = rawMajor;
		let minor = rawMinor;
		let patch = rawPatch;
		if (hasInvalidWildcardOrder(String(major), minor === void 0 ? void 0 : String(minor), patch === void 0 ? void 0 : String(patch))) return comparator;
		const wildcardMajor = isWildcard(major);
		const wildcardMinor = wildcardMajor || isWildcard(minor);
		const wildcardPatch = wildcardMinor || isWildcard(patch);
		if (operator === "=" && wildcardPatch) operator = "";
		if (wildcardMajor) return operator === ">" || operator === "<" ? "<0.0.0-0" : "*";
		let prerelease = options.includePrerelease ? "-0" : "";
		if (operator && wildcardPatch) {
			if (wildcardMinor) minor = 0;
			patch = 0;
			if (operator === ">") {
				operator = ">=";
				if (wildcardMinor) {
					major = Number(major) + 1;
					minor = 0;
				} else minor = Number(minor) + 1;
			} else if (operator === "<=") {
				operator = "<";
				if (wildcardMinor) major = Number(major) + 1;
				else minor = Number(minor) + 1;
			}
			if (operator === "<") prerelease = "-0";
			return `${operator}${major}.${minor}.${patch}${prerelease}`;
		}
		if (wildcardMinor) return `>=${major}.0.0${prerelease} <${Number(major) + 1}.0.0-0`;
		if (wildcardPatch) return `>=${major}.${minor}.0${prerelease} <${major}.${Number(minor) + 1}.0-0`;
		return match;
	});
}
function replaceXRanges(comparator, options) {
	return comparator.split(/\s+/).map((part) => replaceXRange(part, options)).join(" ");
}
function replaceHyphenRange(range, options) {
	const expression = options.loose ? LOOSE_HYPHEN : STRICT_HYPHEN;
	return range.replace(expression, (_match, rawFrom, fromMajor, fromMinor, fromPatch, fromPrerelease, _fromBuild, rawTo, toMajor, toMinor, toPatch, toPrerelease) => {
		let from = rawFrom;
		let to = rawTo;
		if (isWildcard(fromMajor)) from = "";
		else if (isWildcard(fromMinor)) from = `>=${fromMajor}.0.0${options.includePrerelease ? "-0" : ""}`;
		else if (isWildcard(fromPatch)) from = `>=${fromMajor}.${fromMinor}.0${options.includePrerelease ? "-0" : ""}`;
		else if (fromPrerelease) from = `>=${from}`;
		else from = `>=${from}${options.includePrerelease ? "-0" : ""}`;
		if (isWildcard(toMajor)) to = "";
		else if (isWildcard(toMinor)) to = `<${Number(toMajor) + 1}.0.0-0`;
		else if (isWildcard(toPatch)) to = `<${toMajor}.${Number(toMinor) + 1}.0-0`;
		else if (toPrerelease) to = `<=${toMajor}.${toMinor}.${toPatch}-${toPrerelease}`;
		else if (options.includePrerelease) to = `<${toMajor}.${toMinor}.${Number(toPatch) + 1}-0`;
		else to = `<=${to}`;
		return `${from} ${to}`.trim();
	});
}
function expandComparator(comparator, options) {
	return replaceXRanges(replaceTildes(replaceCarets(comparator.replace(BUILD_SAFE, ""), options), options), options).trim().replace(STAR, "");
}
function parseSimpleRange(input, options) {
	let parts = replaceHyphenRange(input.replace(BUILD_STRIP, ""), options).replace(COMPARATOR_TRIM, "$1$2$3").replace(TILDE_TRIM, "$1~").replace(CARET_TRIM, "$1^").split(" ").map((part) => expandComparator(part, options)).join(" ").split(/\s+/).map((part) => part.trim().replace(options.includePrerelease ? GTE_ZERO_PRERELEASE : GTE_ZERO, ""));
	if (options.loose) parts = parts.filter((part) => LOOSE_COMPARATOR.test(part));
	const unique = /* @__PURE__ */ new Map();
	for (const comparator of parts.map((part) => parseComparator(part, options))) {
		if (comparator.value === "<0.0.0-0") return [comparator];
		unique.set(comparator.value, comparator);
	}
	if (unique.size > 1) unique.delete("");
	return [...unique.values()];
}
function parseRange(range, options = {}) {
	if (typeof range !== "string") return range;
	const parsedOptions = { ...options };
	const normalizedRange = range.trim().replaceAll(/\s+/g, " ");
	let sets = normalizedRange.split("||").map((part) => parseSimpleRange(part.trim(), parsedOptions)).filter((set) => set.length);
	if (!sets.length) throw new TypeError(`Range contains no valid comparator sets: ${normalizedRange}`);
	if (sets.length > 1) {
		const first = sets[0];
		sets = sets.filter((set) => set[0]?.value !== "<0.0.0-0");
		if (!sets.length) sets = [first];
		else if (sets.length > 1) {
			const any = sets.find((set) => set.length === 1 && set[0]?.value === "");
			if (any) sets = [any];
		}
	}
	return {
		options: parsedOptions,
		sets
	};
}
function tryParseRange(range, options = {}) {
	try {
		return parseRange(range, options);
	} catch {
		return null;
	}
}
function testParsedRange(range, version) {
	return range.sets.some((set) => testComparatorSet(set, version, range.options));
}
function testRangeVersion(range, version) {
	const parsed = tryParse(version, range.options);
	return parsed ? testParsedRange(range, parsed) : false;
}
function exactVersion(set) {
	for (const comparator of set) if (comparator.operator === "" && comparator.version) return comparator.version;
	return null;
}
function isSatisfiable(comparators, options) {
	const exact = exactVersion(comparators);
	if (exact) return testComparatorSet(comparators, exact, options);
	const remaining = [...comparators];
	let current = remaining.pop();
	while (current && remaining.length) {
		if (remaining.some((other) => !parsedComparatorsIntersect(current, other, options))) return false;
		current = remaining.pop();
	}
	return true;
}
function setsIntersect(left, right, options) {
	const leftExact = exactVersion(left);
	if (leftExact) return testComparatorSet(right, leftExact, options);
	const rightExact = exactVersion(right);
	if (rightExact) return testComparatorSet(left, rightExact, options);
	return left.every((leftComparator) => right.every((rightComparator) => parsedComparatorsIntersect(leftComparator, rightComparator, options)));
}
function parsedRangesIntersect(left, right, options = {}) {
	return left.sets.some((leftSet) => isSatisfiable(leftSet, options) && right.sets.some((rightSet) => isSatisfiable(rightSet, options) && setsIntersect(leftSet, rightSet, options)));
}
//#endregion
//#region src/range/operations.ts
function isValidRange(range, options = {}) {
	return tryParseRange(range, options) !== null;
}
function normalizeRange(range, options = {}) {
	const parsed = tryParseRange(range, options);
	return parsed ? formatRange(parsed) || "*" : null;
}
function satisfies(version, range, options = {}) {
	const parsed = tryParseRange(range, options);
	return parsed ? testRangeVersion(parsed, version) : false;
}
function rangeToComparators(range, options = {}) {
	return parseRange(range, options).sets.map((set) => set.map(formatComparator).join(" ").trim().split(" "));
}
function findMaxSatisfying(versions, range, options = {}) {
	const parsedRange = tryParseRange(range, options);
	if (!parsedRange) return null;
	let maximum = null;
	let maximumParsed = null;
	for (const version of versions) {
		const parsedVersion = tryParse(version, parsedRange.options);
		if (!parsedVersion || !testParsedRange(parsedRange, parsedVersion)) continue;
		if (!maximumParsed || compareParsed(maximumParsed, parsedVersion) < 0) {
			maximum = version;
			maximumParsed = parsedVersion;
		}
	}
	return maximum;
}
function findMinSatisfying(versions, range, options = {}) {
	const parsedRange = tryParseRange(range, options);
	if (!parsedRange) return null;
	let minimum = null;
	let minimumParsed = null;
	for (const version of versions) {
		const parsedVersion = tryParse(version, parsedRange.options);
		if (!parsedVersion || !testParsedRange(parsedRange, parsedVersion)) continue;
		if (!minimumParsed || compareParsed(minimumParsed, parsedVersion) > 0) {
			minimum = version;
			minimumParsed = parsedVersion;
		}
	}
	return minimum;
}
function nextVersionAfter(version) {
	const { prerelease } = version;
	return prerelease?.length ? {
		major: version.major,
		minor: version.minor,
		patch: version.patch,
		prerelease: [...prerelease, 0]
	} : {
		major: version.major,
		minor: version.minor,
		patch: version.patch + 1
	};
}
function findMinimumForRange(range, options = {}) {
	const parsedRange = parseRange(range, options);
	const zero = {
		major: 0,
		minor: 0,
		patch: 0
	};
	if (testParsedRange(parsedRange, zero)) return zero;
	const zeroPrerelease = {
		...zero,
		prerelease: [0]
	};
	if (testParsedRange(parsedRange, zeroPrerelease)) return zeroPrerelease;
	let minimum = null;
	for (const set of parsedRange.sets) {
		let setMinimum = null;
		for (const comparator of set) {
			if (!comparator.version) continue;
			const candidate = comparator.operator === ">" ? nextVersionAfter(comparator.version) : comparator.operator === "" || comparator.operator === ">=" ? structuredClone(comparator.version) : null;
			if (candidate && (!setMinimum || compareParsed(candidate, setMinimum) > 0)) setMinimum = candidate;
		}
		if (setMinimum && (!minimum || compareParsed(minimum, setMinimum) > 0)) minimum = setMinimum;
	}
	return minimum && testParsedRange(parsedRange, minimum) ? minimum : null;
}
function compareInDirection(left, right, direction) {
	const comparison = compareParsed(left, right);
	return direction === ">" ? comparison > 0 : comparison < 0;
}
function compareOppositeOrEqual(left, right, direction) {
	const comparison = compareParsed(left, right);
	return direction === ">" ? comparison <= 0 : comparison >= 0;
}
function compareOpposite(left, right, direction) {
	const comparison = compareParsed(left, right);
	return direction === ">" ? comparison < 0 : comparison > 0;
}
function isOutsideRange(version, range, direction, options = {}) {
	if (direction !== ">" && direction !== "<") throw new TypeError("Must provide a direction of \"<\" or \">\"");
	const parsedRange = parseRange(range, options);
	const parsedVersion = parse(version, parsedRange.options);
	if (testParsedRange(parsedRange, parsedVersion)) return false;
	const inclusiveDirection = direction === ">" ? ">=" : "<=";
	for (const set of parsedRange.sets) {
		const concrete = set.map((comparator) => comparator.version ? comparator : parseComparator(">=0.0.0"));
		let high = concrete[0];
		let low = concrete[0];
		for (const comparator of concrete) if (compareInDirection(comparator.version, high.version, direction)) high = comparator;
		else if (compareOpposite(comparator.version, low.version, direction)) low = comparator;
		if (high.operator === direction || high.operator === inclusiveDirection) return false;
		if ((!low.operator || low.operator === direction) && compareOppositeOrEqual(parsedVersion, low.version, direction)) return false;
		if (low.operator === inclusiveDirection && compareOpposite(parsedVersion, low.version, direction)) return false;
	}
	return true;
}
function isGreaterThanRange(version, range, options = {}) {
	return isOutsideRange(version, range, ">", options);
}
function isLessThanRange(version, range, options = {}) {
	return isOutsideRange(version, range, "<", options);
}
function rangesIntersect(left, right, options = {}) {
	const parsedLeft = parseRange(left, options);
	const parsedRight = parseRange(right, options);
	return parsedRangesIntersect(parsedLeft, parsedRight, {
		...parsedLeft.options,
		...parsedRight.options,
		...options
	});
}
function simplifyRange(versions, range, options = {}) {
	const parsedRange = parseRange(range, options);
	const sorted = sort(versions, parsedRange.options);
	const sets = [];
	let first = null;
	let previous = null;
	for (const version of sorted) if (testRangeVersion(parsedRange, version)) {
		previous = version;
		first ??= version;
	} else if (previous) {
		sets.push([first, previous]);
		first = null;
		previous = null;
	}
	if (first) sets.push([first, null]);
	const simplified = sets.map(([minimum, maximum]) => {
		const minimumValue = formatComparableVersion(parse(minimum, parsedRange.options));
		const maximumValue = maximum ? formatComparableVersion(parse(maximum, parsedRange.options)) : null;
		if (minimumValue === maximumValue) return minimumValue;
		if (!maximum && minimum === sorted[0]) return "*";
		if (!maximumValue) return `>=${minimumValue}`;
		if (minimum === sorted[0]) return `<=${maximumValue}`;
		return `${minimumValue} - ${maximumValue}`;
	}).join(" || ");
	const original = typeof range === "string" ? range : formatRange(parsedRange) || "*";
	return simplified.length < original.length ? simplified : original;
}
//#endregion
//#region src/range/subset.ts
function higherLowerBound(left, right) {
	if (!left) return right;
	const comparison = compareParsed(left.version, right.version);
	return comparison > 0 ? left : comparison < 0 || right.operator === ">" && left.operator === ">=" ? right : left;
}
function lowerUpperBound(left, right) {
	if (!left) return right;
	const comparison = compareParsed(left.version, right.version);
	return comparison < 0 ? left : comparison > 0 || right.operator === "<" && left.operator === "<=" ? right : left;
}
function simpleRangeSubset(rawSubset, rawSuperset, options) {
	let subset = rawSubset;
	let superset = rawSuperset;
	const subsetAny = subset.length === 1 && !subset[0].version;
	const supersetAny = superset.length === 1 && !superset[0].version;
	if (subsetAny) {
		if (supersetAny) return true;
		subset = [parseComparator(options.includePrerelease ? ">=0.0.0-0" : ">=0.0.0")];
	}
	if (supersetAny) {
		if (options.includePrerelease) return true;
		superset = [parseComparator(">=0.0.0")];
	}
	const equal = /* @__PURE__ */ new Map();
	let lower;
	let upper;
	for (const comparator of subset) if (comparator.operator === ">" || comparator.operator === ">=") lower = higherLowerBound(lower, comparator);
	else if (comparator.operator === "<" || comparator.operator === "<=") upper = lowerUpperBound(upper, comparator);
	else if (comparator.version) equal.set(formatComparableVersion(comparator.version), comparator.version);
	if (equal.size > 1) return null;
	let boundsComparison;
	if (lower && upper) {
		boundsComparison = compareParsed(lower.version, upper.version);
		if (boundsComparison > 0) return null;
		if (boundsComparison === 0 && (lower.operator !== ">=" || upper.operator !== "<=")) return null;
	}
	for (const version of equal.values()) {
		if (lower && !testParsedComparator(lower, version)) return null;
		if (upper && !testParsedComparator(upper, version)) return null;
		return testComparatorSet(superset, version, options);
	}
	let needsLowerPrerelease = lower && !options.includePrerelease && lower.version.prerelease?.length ? lower.version : null;
	let needsUpperPrerelease = upper && !options.includePrerelease && upper.version.prerelease?.length ? upper.version : null;
	const upperPrerelease = needsUpperPrerelease?.prerelease;
	if (upperPrerelease?.length === 1 && upper?.operator === "<" && upperPrerelease[0] === 0) needsUpperPrerelease = null;
	let hasSupersetLower = false;
	let hasSupersetUpper = false;
	for (const comparator of superset) {
		hasSupersetLower ||= comparator.operator === ">" || comparator.operator === ">=";
		hasSupersetUpper ||= comparator.operator === "<" || comparator.operator === "<=";
		if (lower) {
			if (needsLowerPrerelease && comparatorAllowsPrerelease(comparator, needsLowerPrerelease)) needsLowerPrerelease = null;
			if (comparator.operator === ">" || comparator.operator === ">=") {
				const higher = higherLowerBound(lower, comparator);
				if (higher === comparator && higher !== lower) return false;
			} else if (lower.operator === ">=" && !testParsedComparator(comparator, lower.version)) return false;
		}
		if (upper) {
			if (needsUpperPrerelease && comparatorAllowsPrerelease(comparator, needsUpperPrerelease)) needsUpperPrerelease = null;
			if (comparator.operator === "<" || comparator.operator === "<=") {
				const lowerBound = lowerUpperBound(upper, comparator);
				if (lowerBound === comparator && lowerBound !== upper) return false;
			} else if (upper.operator === "<=" && !testParsedComparator(comparator, upper.version)) return false;
		}
		if (comparator.operator === "" && (lower || upper) && boundsComparison !== 0) return false;
	}
	if (lower && hasSupersetUpper && !upper && boundsComparison !== 0) return false;
	if (upper && hasSupersetLower && !lower && boundsComparison !== 0) return false;
	return !needsLowerPrerelease && !needsUpperPrerelease;
}
function isRangeSubset(subset, superset, options = {}) {
	if (subset === superset) return true;
	const parsedSubset = parseRange(subset, options);
	const parsedSuperset = parseRange(superset, options);
	const effectiveOptions = {
		...parsedSubset.options,
		...parsedSuperset.options,
		...options
	};
	let sawNonNull = false;
	for (const subsetSet of parsedSubset.sets) {
		let matched = false;
		for (const supersetSet of parsedSuperset.sets) {
			const result = simpleRangeSubset(subsetSet, supersetSet, effectiveOptions);
			sawNonNull ||= result !== null;
			if (result) {
				matched = true;
				break;
			}
		}
		if (!matched && sawNonNull) return false;
	}
	return true;
}
//#endregion
export { isGreaterThanRange as a, isValidRange as c, rangesIntersect as d, satisfies as f, tryParseRange as h, findMinimumForRange as i, normalizeRange as l, parseRange as m, findMaxSatisfying as n, isLessThanRange as o, simplifyRange as p, findMinSatisfying as r, isOutsideRange as s, isRangeSubset as t, rangeToComparators as u };
