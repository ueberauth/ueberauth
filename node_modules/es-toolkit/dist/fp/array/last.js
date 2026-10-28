const require_last = require("../../array/last.js");
// src/fp/array/last.ts
/**
* Creates a function that returns the last element of an array, or undefined.
*
* Empty arrays return undefined, matching the main {@link last} behavior. Use
* the returned function with {@link pipe}.
*
* @template T - The type of elements in the array.
* @returns A function that maps a readonly array to its last element, or undefined.
*
* @example
* import { last, pipe } from 'es-toolkit/fp';
*
* pipe([1, 2, 3], last());
* // => 3
*
* pipe([] as number[], last());
* // => undefined
*/
function last() {
	return function(array) {
		return require_last.last(array);
	};
}
exports.last = last;
