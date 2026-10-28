const require_intersection = require("../../array/intersection.js");
const require_uniq = require("../../array/uniq.js");
const require_toArray = require("../_internal/toArray.js");
const require_isArrayLikeObject = require("../predicate/isArrayLikeObject.js");
// src/compat/array/intersection.ts
/**
* Returns the intersection of multiple arrays.
*
* This function takes multiple arrays and returns a new array containing the elements that are
* present in all provided arrays. It effectively filters out any elements that are not found
* in every array.
*
* @template T - The type of elements in the arrays.
* @param arrays - The arrays to compare.
* @returns A new array containing the elements that are present in all arrays.
*
* @example
* const array1 = [1, 2, 3, 4, 5];
* const array2 = [3, 4, 5, 6, 7];
* const result = intersection(array1, array2);
* // result will be [3, 4, 5] since these elements are in both arrays.
*/
function intersection(...arrays) {
	if (arrays.length === 0) return [];
	if (!require_isArrayLikeObject.isArrayLikeObject(arrays[0])) return [];
	let result = require_uniq.uniq(require_toArray.toArray(arrays[0]));
	for (let i = 1; i < arrays.length; i++) {
		const array = arrays[i];
		if (!require_isArrayLikeObject.isArrayLikeObject(array)) return [];
		result = require_intersection.intersection(result, require_toArray.toArray(array));
	}
	return result;
}
exports.intersection = intersection;
