const require_hasOwn = require("./hasOwn.js");
// src/compat/_internal/basePull.ts
/**
* A copy of `pull` from `es-toolkit/array` that only relies on ES2015 built-ins,
* so that `es-toolkit/compat` runs on Node.js 6 without changing the main library.
*
* @template T
* @param arr - The array to modify.
* @param valuesToRemove - The values to remove from the array.
* @returns The modified array with the specified values removed.
*/
function basePull(arr, valuesToRemove) {
	const valuesSet = new Set(valuesToRemove);
	let resultIndex = 0;
	for (let i = 0; i < arr.length; i++) {
		if (valuesSet.has(arr[i])) continue;
		if (!require_hasOwn.hasOwn(arr, i)) {
			delete arr[resultIndex++];
			continue;
		}
		arr[resultIndex++] = arr[i];
	}
	arr.length = resultIndex;
	return arr;
}
exports.basePull = basePull;
