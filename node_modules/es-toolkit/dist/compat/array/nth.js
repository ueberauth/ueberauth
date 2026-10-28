const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_toInteger = require("../util/toInteger.js");
// src/compat/array/nth.ts
/**
* Gets the element at index `n` of `array`. If `n` is negative, the nth element from the end is returned.
*
* @param array - The array to query.
* @param [n=0] - The index of the element to return.
* @return {T | undefined} Returns the nth element of `array`.
*
* @example
* nth([1, 2, 3], 1); // => 2
* nth([1, 2, 3], -1); // => 3
*/
function nth(array, n = 0) {
	if (!require_isArrayLike.isArrayLike(array) || array.length === 0) return;
	n = require_toInteger.toInteger(n);
	if (n < 0) n += array.length;
	return array[n];
}
exports.nth = nth;
