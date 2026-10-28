import { head as head$1 } from "../../array/head.mjs";
// src/fp/array/head.ts
/**
* Creates a function that returns the first element of an array, or undefined.
*
* Empty arrays return undefined, matching the main {@link head} behavior. Use
* the returned function with {@link pipe}.
*
* @template T - The type of elements in the array.
* @returns A function that maps a readonly array to its first element, or undefined.
*
* @example
* import { head, pipe } from 'es-toolkit/fp';
*
* pipe([1, 2, 3], head());
* // => 1
*
* pipe([] as number[], head());
* // => undefined
*/
function head() {
	return function(array) {
		return head$1(array);
	};
}
export { head };
