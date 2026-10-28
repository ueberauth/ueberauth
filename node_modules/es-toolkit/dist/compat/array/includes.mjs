import { eq } from "../util/eq.mjs";
import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { toInteger } from "../util/toInteger.mjs";
import { isString } from "../predicate/isString.mjs";
// src/compat/array/includes.ts
/**
* Checks if a specified value exists within a given source, which can be an array, an object, or a string.
*
* The comparison uses SameValueZero to check for inclusion.
*
* @param collection - The source to search in. It can be an array, an object, or a string.
* @param [target] - The value to search for in the source.
* @param [fromIndex=0] - The index to start searching from. If negative, it is treated as an offset from the end of the source.
* @returns `true` if the value is found in the source, `false` otherwise.
*
* @example
* includes([1, 2, 3], 2); // true
* includes({ a: 1, b: 'a', c: NaN }, 'a'); // true
* includes('hello world', 'world'); // true
* includes('hello world', 'test'); // false
*/
function includes(collection, target, fromIndex, guard) {
	if (collection == null) return false;
	if (guard || !fromIndex) fromIndex = 0;
	else fromIndex = toInteger(fromIndex);
	if (isString(collection)) {
		if (fromIndex > collection.length || target instanceof RegExp) return false;
		if (fromIndex < 0) fromIndex = Math.max(0, collection.length + fromIndex);
		return collection.includes(target, fromIndex);
	}
	if (Array.isArray(collection)) return collection.includes(target, fromIndex);
	if (isArrayLike(collection)) {
		if (fromIndex < 0) fromIndex = Math.max(0, collection.length + fromIndex);
		for (let i = fromIndex; i < collection.length; i++) if (eq(collection[i], target)) return true;
		return false;
	}
	const keys = Object.keys(collection);
	if (fromIndex < 0) fromIndex = Math.max(0, keys.length + fromIndex);
	for (let i = fromIndex; i < keys.length; i++) {
		const value = Reflect.get(collection, keys[i]);
		if (eq(value, target)) return true;
	}
	return false;
}
export { includes };
