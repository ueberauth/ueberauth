import { basePull } from "../_internal/basePull.mjs";
// src/compat/array/pullAll.ts
/**
* Removes all specified values from an array.
*
* This function changes `arr` in place.
* If you want to remove values without modifying the original array, use `difference`.
*
* @template T
* @param arr - The array to modify.
* @param valuesToRemove - The values to remove from the array.
* @returns The modified array with the specified values removed.
*
* @example
* const numbers = [1, 2, 3, 4, 5, 2, 4];
* pullAll(numbers, [2, 4]);
* console.log(numbers); // [1, 3, 5]
*/
function pullAll(arr, valuesToRemove = []) {
	if ((arr === null || arr === void 0 ? void 0 : arr.length) == null || (valuesToRemove === null || valuesToRemove === void 0 ? void 0 : valuesToRemove.length) == null) return arr;
	return basePull(arr, Array.from(valuesToRemove));
}
export { pullAll };
