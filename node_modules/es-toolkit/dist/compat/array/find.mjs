import { identity } from "../../function/identity.mjs";
import { range } from "../../math/range.mjs";
import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { iteratee } from "../util/iteratee.mjs";
import { toInteger } from "../util/toInteger.mjs";
// src/compat/array/find.ts
/**
* Finds the first item in an object that has a specific property, where the property name is provided as a PropertyKey.
*
* @template T
* @param collection - The source array or object to search through.
* @param [doesMatch=identity] - The criteria to match. It can be a function, a partial object, a key-value pair, or a property name.
* @param [fromIndex=0] - The index to start the search from, defaults to 0.
* @returns The first property value that has the specified property, or `undefined` if no match is found.
*
* @example
* // Using a property name
* const obj = { a: { id: 1, name: 'Alice' }, b: { id: 2, name: 'Bob' } };
* const result = find(obj, 'name');
* console.log(result); // { id: 1, name: 'Alice' }
*/
function find(collection, _doesMatch = identity, fromIndex = 0) {
	if (!collection) return;
	const doesMatch = iteratee(_doesMatch);
	const keys = isArrayLike(collection) ? range(0, collection.length) : Object.keys(collection);
	fromIndex = toInteger(fromIndex);
	if (!fromIndex) fromIndex = 0;
	if (fromIndex < 0) fromIndex = Math.max(keys.length + fromIndex, 0);
	for (let i = fromIndex; i < keys.length; i++) {
		const key = keys[i];
		const value = collection[key];
		if (doesMatch(value, key, collection)) return value;
	}
}
export { find };
