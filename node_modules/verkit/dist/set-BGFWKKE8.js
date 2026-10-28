import { A as LOOSE_PLAIN, D as GREATER_LESS_THAN, E as FULL_PLAIN, F as safeRegex, S as tryParse, a as compareParsed, x as parse, y as formatComparableVersion } from "./comparison-CmVirWIW.js";
//#region src/comparator/parse.ts
const STRICT_COMPARATOR = safeRegex(String.raw`^${GREATER_LESS_THAN}\s*(${FULL_PLAIN})$|^$`);
const LOOSE_COMPARATOR = safeRegex(String.raw`^${GREATER_LESS_THAN}\s*(${LOOSE_PLAIN})$|^$`);
function formatComparator(comparator) {
	return comparator.version ? `${comparator.operator}${formatComparableVersion(comparator.version)}` : "";
}
function parseComparator(comparator, options = {}) {
	if (typeof comparator !== "string") return comparator;
	const normalized = comparator.trim().replaceAll(/\s+/g, " ");
	const match = normalized.match(options.loose ? LOOSE_COMPARATOR : STRICT_COMPARATOR);
	if (!match) throw new TypeError(`Invalid comparator: ${normalized}`);
	const operator = match[1] === "=" ? "" : match[1] || "";
	const version = match[2] ? parse(match[2], options) : null;
	return {
		operator,
		options,
		value: version ? `${operator}${formatComparableVersion(version)}` : "",
		version
	};
}
function tryParseComparator(comparator, options = {}) {
	try {
		return typeof comparator === "string" ? parseComparator(comparator, options) : comparator;
	} catch {
		return null;
	}
}
//#endregion
//#region src/comparator/set.ts
function testParsedComparator(comparator, version) {
	if (!comparator.version) return true;
	const comparison = compareParsed(version, comparator.version);
	switch (comparator.operator) {
		case "": return comparison === 0;
		case ">": return comparison > 0;
		case ">=": return comparison >= 0;
		case "<": return comparison < 0;
		case "<=": return comparison <= 0;
	}
}
function testComparatorVersion(comparator, version) {
	const parsed = tryParse(version, comparator.options);
	return parsed ? testParsedComparator(comparator, parsed) : false;
}
function comparatorAllowsPrerelease(comparator, version) {
	const allowed = comparator.version;
	return allowed !== null && !!allowed.prerelease?.length && allowed.major === version.major && allowed.minor === version.minor && allowed.patch === version.patch;
}
function testComparatorSet(set, version, options) {
	if (set.some((comparator) => !testParsedComparator(comparator, version))) return false;
	return !version.prerelease?.length || !!options.includePrerelease || set.some((comparator) => comparatorAllowsPrerelease(comparator, version));
}
function parsedComparatorsIntersect(left, right, options = {}) {
	if (!left.version || !right.version) return true;
	if (left.operator === "") return testComparatorSet([right], left.version, options);
	if (right.operator === "") return testComparatorSet([left], right.version, options);
	const leftValue = formatComparator(left);
	const rightValue = formatComparator(right);
	if (options.includePrerelease && (leftValue === "<0.0.0-0" || rightValue === "<0.0.0-0")) return false;
	if (!options.includePrerelease && (leftValue.startsWith("<0.0.0") || rightValue.startsWith("<0.0.0"))) return false;
	if (left.operator.startsWith(">") && right.operator.startsWith(">")) return true;
	if (left.operator.startsWith("<") && right.operator.startsWith("<")) return true;
	const comparison = compareParsed(left.version, right.version);
	if (comparison === 0 && left.operator.includes("=") && right.operator.includes("=")) return true;
	if (comparison < 0 && left.operator.startsWith(">") && right.operator.startsWith("<")) return true;
	return comparison > 0 && left.operator.startsWith("<") && right.operator.startsWith(">");
}
//#endregion
export { testParsedComparator as a, tryParseComparator as c, testComparatorVersion as i, parsedComparatorsIntersect as n, formatComparator as o, testComparatorSet as r, parseComparator as s, comparatorAllowsPrerelease as t };
