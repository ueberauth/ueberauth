import { flatMapDepth } from "./flatMapDepth.mjs";
// src/compat/array/flatMap.ts
/**
* Creates a flattened array of values by running each element in collection through iteratee and flattening the mapped results.
*
* @template R
* @param collection - The collection to iterate over.
* @param [iteratee=identity] - The function invoked per iteration.
* @returns Returns the new flattened array.
*
* @example
* flatMap([1, 2], n => [n, n * 2]);
* // => [1, 2, 2, 4]
*/
function flatMap(collection, iteratee) {
	return flatMapDepth(collection, iteratee, 1);
}
export { flatMap };
