const require_intersectionWith = require("../../array/intersectionWith.js");
const require_uniq = require("../../array/uniq.js");
const require_uniqWith = require("../../array/uniqWith.js");
const require_eq = require("../util/eq.js");
const require_toArray = require("../_internal/toArray.js");
const require_last = require("./last.js");
// src/compat/array/intersectionWith.ts
/**
* Returns the intersection of multiple arrays based on a custom equality function.
*
* @template T - The type of elements in the arrays
* @param firstArr - The first array to compare
* @param otherArrs - Additional arrays and optional equality function
* @returns Elements from first array that match in all arrays
*
* @example
* const arr1 = [{id: 1}, {id: 2}];
* const arr2 = [{id: 2}, {id: 3}];
* const result = intersectionWith(arr1, arr2, (a, b) => a.id === b.id);
* // result is [{id: 2}]
*/
function intersectionWith(firstArr, ...otherArrs) {
	if (firstArr == null) return [];
	const _comparator = require_last.last(otherArrs);
	let comparator = require_eq.eq;
	let uniq$1 = require_uniq.uniq;
	if (typeof _comparator === "function") {
		comparator = _comparator;
		uniq$1 = (arr) => require_uniqWith.uniqWith(arr, comparator);
		otherArrs.pop();
	}
	let result = uniq$1(require_toArray.toArray(firstArr));
	for (let i = 0; i < otherArrs.length; ++i) {
		const otherArr = otherArrs[i];
		if (otherArr == null) return [];
		result = require_intersectionWith.intersectionWith(result, require_toArray.toArray(otherArr), comparator);
	}
	return result;
}
exports.intersectionWith = intersectionWith;
