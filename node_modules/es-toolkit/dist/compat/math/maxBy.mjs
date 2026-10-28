import { identity } from "../../function/identity.mjs";
import { toArray } from "../_internal/toArray.mjs";
import { iteratee } from "../util/iteratee.mjs";
// src/compat/math/maxBy.ts
/**
* Finds the element in an array that has the maximum value when applying
* the `iteratee` to each element.
*
* @template T - The type of elements in the array.
* @param items The array of elements to search.
* @param [iteratee=identity]
* The criteria used to determine the maximum value.
*  - If a **function** is provided, it extracts a numeric value from each element.
*  - If a **string** is provided, it is treated as a key to extract values from the objects.
*  - If a **[key, value]** pair is provided, it matches elements with the specified key-value pair.
*  - If an **object** is provided, it matches elements that contain the specified properties.
* @returns The element with the maximum value as determined by the `iteratee`.
* @example
* maxBy([{ a: 1 }, { a: 2 }, { a: 3 }], x => x.a); // Returns: { a: 3 }
* maxBy([], x => x.a); // Returns: undefined
* maxBy(
*   [
*     { name: 'john', age: 30 },
*     { name: 'jane', age: 28 },
*     { name: 'joe', age: 26 },
*   ],
*   x => x.age
* ); // Returns: { name: 'john', age: 30 }
* maxBy([{ a: 1 }, { a: 2 }], 'a'); // Returns: { a: 2 }
* maxBy([{ a: 1 }, { a: 2 }], ['a', 1]); // Returns: { a: 1 }
* maxBy([{ a: 1 }, { a: 2 }], { a: 1 }); // Returns: { a: 1 }
*/
function maxBy(items, iteratee$1 = identity) {
	if (items == null) return;
	const array = toArray(items);
	if (array.length === 0) return;
	const getValue = iteratee(iteratee$1);
	let maxElement;
	let max;
	for (let i = 0; i < array.length; i++) {
		const element = array[i];
		const current = getValue(element);
		if (current == null || Number.isNaN(current) || typeof current === "symbol") continue;
		if (max === void 0 || current > max) {
			max = current;
			maxElement = element;
		}
	}
	return maxElement;
}
export { maxBy };
