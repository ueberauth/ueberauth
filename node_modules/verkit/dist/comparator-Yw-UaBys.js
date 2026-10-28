import { i as testComparatorVersion, n as parsedComparatorsIntersect, o as formatComparator, s as parseComparator } from "./set-BGFWKKE8.js";
//#region src/comparator/operations.ts
function resolveComparator(comparator, options) {
	return typeof comparator === "string" ? parseComparator(comparator, options) : comparator;
}
function normalizeComparator(comparator, options = {}) {
	return formatComparator(resolveComparator(comparator, options));
}
function satisfiesComparator(version, comparator, options = {}) {
	return testComparatorVersion(resolveComparator(comparator, options), version);
}
function comparatorsIntersect(left, right, options = {}) {
	const parsedLeft = resolveComparator(left, options);
	const parsedRight = resolveComparator(right, options);
	return parsedComparatorsIntersect(parsedLeft, parsedRight, {
		...parsedLeft.options,
		...parsedRight.options,
		...options
	});
}
//#endregion
export { normalizeComparator as n, satisfiesComparator as r, comparatorsIntersect as t };
