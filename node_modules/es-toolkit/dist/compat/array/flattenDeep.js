const require_flattenDepth = require("./flattenDepth.js");
// src/compat/array/flattenDeep.ts
/**
* Recursively flattens array.
*
* @template T
* @param array - The array to flatten.
* @returns Returns the new flattened array.
*
* @example
* flattenDeep([1, [2, [3, [4]], 5]]);
* // => [1, 2, 3, 4, 5]
*/
function flattenDeep(array) {
	return require_flattenDepth.flattenDepth(array, Infinity);
}
exports.flattenDeep = flattenDeep;
