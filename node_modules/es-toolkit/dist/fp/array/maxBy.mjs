import { maxBy as maxBy$1 } from "../../array/maxBy.mjs";
// src/fp/array/maxBy.ts
/**
* Creates a function that returns the element with the maximum selected number.
*
* Empty arrays return undefined. If the selector returns NaN, the element that
* produced NaN is returned, matching the main {@link maxBy} behavior.
*
* @template T - The type of elements in the array.
* @param getValue - Selects a numeric value from each element, index, and array.
* @returns A function that maps a readonly array to the maximum element, or undefined.
*
* @example
* import { maxBy, pipe } from 'es-toolkit/fp';
*
* pipe([{ score: 10 }, { score: 20 }], maxBy(item => item.score));
* // => { score: 20 }
*
* pipe([] as Array<{ score: number }>, maxBy(item => item.score));
* // => undefined
*/
function maxBy(getValue) {
	return function(array) {
		return maxBy$1(array, getValue);
	};
}
export { maxBy };
