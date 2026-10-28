import { flattenDepth } from "./flattenDepth.mjs";
// src/compat/array/flatten.ts
/**
* Flattens array up to depth times.
*
* @template T
* @param array - The array to flatten.
* @returns Returns the new flattened array.
*
* @example
* flatten([1, [2, [3, [4]], 5]]);
* // => [1, 2, [3, [4]], 5]
*/
function flatten(array) {
	return flattenDepth(array, 1);
}
export { flatten };
