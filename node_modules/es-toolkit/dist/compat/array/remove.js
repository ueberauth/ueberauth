const require_identity = require("../../function/identity.js");
const require_hasOwn = require("../_internal/hasOwn.js");
const require_iteratee = require("../util/iteratee.js");
// src/compat/array/remove.ts
/**
* Removes elements from an array based on various criteria.
*
* @param arr - The array to iterate over.
* @param shouldRemoveElement - The function invoked per iteration, a partial object, a property-value pair, or a key to match against each element.
* @returns Returns the modified array with the specified elements removed.
*
* @example
* // Using a predicate function
* const numbers = [1, 2, 3, 4, 5];
* remove(numbers, value => value % 2 === 0); // => [2, 4]
* console.log(numbers); // => [1, 3, 5]
*
* @example
* // Using a partial object
* const objects = [{ a: 1 }, { a: 2 }, { a: 3 }];
* remove(objects, { a: 1 }); // => [{ a: 1 }]
* console.log(objects); // => [{ a: 2 }, { a: 3 }]
*
* @example
* // Using a property-value pair
* const objects = [{ a: 1 }, { a: 2 }, { a: 3 }];
* remove(objects, ['a', 1]); // => [{ a: 1 }]
* console.log(objects); // => [{ a: 2 }, { a: 3 }]
*
* @example
* // Using a property key
* const objects = [{ a: 0 }, { a: 1 }];
* remove(objects, 'a'); // => [{ a: 1 }]
* console.log(objects); // => [{ a: 0 }]
*/
function remove(arr, shouldRemoveElement = require_identity.identity) {
	if ((arr === null || arr === void 0 ? void 0 : arr.length) == null) return [];
	return removeImpl(arr, require_iteratee.iteratee(shouldRemoveElement));
}
function removeImpl(arr, shouldRemoveElement) {
	const originalArr = arr.slice();
	const removed = [];
	let resultIndex = 0;
	for (let i = 0; i < arr.length; i++) {
		if (shouldRemoveElement(arr[i], i, originalArr)) {
			removed.push(arr[i]);
			continue;
		}
		if (!require_hasOwn.hasOwn(arr, i)) {
			delete arr[resultIndex++];
			continue;
		}
		arr[resultIndex++] = arr[i];
	}
	arr.length = resultIndex;
	return removed;
}
exports.remove = remove;
