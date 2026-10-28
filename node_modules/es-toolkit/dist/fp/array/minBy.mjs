import { minBy as minBy$1 } from "../../array/minBy.mjs";
// src/fp/array/minBy.ts
/**
* Creates a function that returns the element with the minimum selected number.
*
* Empty arrays return undefined. If the selector returns NaN, the element that
* produced NaN is returned, matching the main {@link minBy} behavior.
*
* @template T - The type of elements in the array.
* @param getValue - Selects a numeric value from each element, index, and array.
* @returns A function that maps a readonly array to the minimum element, or undefined.
*
* @example
* import { minBy, pipe } from 'es-toolkit/fp';
*
* pipe([{ score: 10 }, { score: 20 }], minBy(item => item.score));
* // => { score: 10 }
*
* pipe([] as Array<{ score: number }>, minBy(item => item.score));
* // => undefined
*/
function minBy(getValue) {
	return function(array) {
		return minBy$1(array, getValue);
	};
}
export { minBy };
