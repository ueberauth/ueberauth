import { identity } from "../../function/identity.mjs";
import { iteratee } from "../util/iteratee.mjs";
import { flattenDepth } from "./flattenDepth.mjs";
import { map } from "./map.mjs";
// src/compat/array/flatMapDepth.ts
/**
* Creates a flattened array of values by running each element through iteratee and flattening the mapped results up to depth times.
*
* @template T, R
* @param collection - The array or object to iterate over.
* @param [iteratee=identity] - The function that produces the new array elements.
* @param [depth=1] - The maximum recursion depth.
* @returns A new array that has been flattened up to the specified depth.
*
* @example
* flatMapDepth([1, 2, 3], n => [[n, n]], 2);
* // => [1, 1, 2, 2, 3, 3]
*/
function flatMapDepth(collection, iteratee$1 = identity, depth = 1) {
	if (collection == null) return [];
	const iterateeFn = iteratee(iteratee$1);
	const mapped = map(collection, iterateeFn);
	return flattenDepth(mapped, depth);
}
export { flatMapDepth };
