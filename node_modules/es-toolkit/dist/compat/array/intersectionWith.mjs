import { intersectionWith as intersectionWith$1 } from "../../array/intersectionWith.mjs";
import { uniq } from "../../array/uniq.mjs";
import { uniqWith } from "../../array/uniqWith.mjs";
import { eq } from "../util/eq.mjs";
import { toArray } from "../_internal/toArray.mjs";
import { last } from "./last.mjs";
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
	const _comparator = last(otherArrs);
	let comparator = eq;
	let uniq$1 = uniq;
	if (typeof _comparator === "function") {
		comparator = _comparator;
		uniq$1 = (arr) => uniqWith(arr, comparator);
		otherArrs.pop();
	}
	let result = uniq$1(toArray(firstArr));
	for (let i = 0; i < otherArrs.length; ++i) {
		const otherArr = otherArrs[i];
		if (otherArr == null) return [];
		result = intersectionWith$1(result, toArray(otherArr), comparator);
	}
	return result;
}
export { intersectionWith };
