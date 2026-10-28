const require_isArray = require("../predicate/isArray.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_isArguments = require("../predicate/isArguments.js");
// src/compat/array/flattenDepth.ts
/**
* Recursively flattens array up to depth times.
*
* @template T
* @param array - The array to flatten.
* @param [depth=1] - The maximum recursion depth.
* @returns Returns the new flattened array.
*
* @example
* const array = [1, [2, [3, [4]], 5]];
*
* flattenDepth(array, 1);
* // => [1, 2, [3, [4]], 5]
*
* flattenDepth(array, 2);
* // => [1, 2, 3, [4], 5]
*/
function flattenDepth(array, depth = 1) {
	if (!require_isArrayLike.isArrayLike(array)) return [];
	const result = [];
	const flooredDepth = Math.floor(depth);
	const recursive = (arr, currentDepth) => {
		for (let i = 0; i < arr.length; i++) {
			const item = arr[i];
			if (isFlattenable(item) && currentDepth < flooredDepth) recursive(item, currentDepth + 1);
			else result.push(item);
		}
	};
	recursive(Array.from(array), 0);
	return result;
}
function isFlattenable(value) {
	return require_isArray.isArray(value) || require_isArguments.isArguments(value) || Boolean(value && value[Symbol.isConcatSpreadable]);
}
exports.flattenDepth = flattenDepth;
