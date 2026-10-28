const require_identity = require("../../function/identity.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_iteratee = require("../util/iteratee.js");
// src/compat/array/filter.ts
/**
* Iterates over the collection and filters elements based on the given predicate.
* If a function is provided, it is invoked for each element in the collection.
*
* @template T
* @param collection - The array or object to iterate over.
* @param [predicate=identity] - The function invoked per iteration.
* @returns Returns a new array of filtered elements that satisfy the predicate.
*
* @example
* filter([{ a: 1 }, { a: 2 }, { b: 1 }], 'a');
* // => [{ a: 1 }, { a: 2 }]
*
* filter([{ a: 1 }, { a: 2 }, { b: 1 }], { b: 1 });
* // => [{ b: 1 }]
*
* filter({ item1: { a: 0, b: true }, item2: { a: 1, b: true }, item3: { a: 2, b: false }}, { b: false })
* // => [{ a: 2, b: false }]
*
* filter([{ a: 1 }, { a: 2 }, { a: 3 }], ['a', 2]);
* // => [{ a: 2 }]
*/
function filter(collection, predicate = require_identity.identity) {
	if (!collection) return [];
	predicate = require_iteratee.iteratee(predicate);
	if (!Array.isArray(collection)) {
		const result = [];
		const keys = Object.keys(collection);
		const length = require_isArrayLike.isArrayLike(collection) ? collection.length : keys.length;
		for (let i = 0; i < length; i++) {
			const key = keys[i];
			const value = collection[key];
			if (predicate(value, key, collection)) result.push(value);
		}
		return result;
	}
	const result = [];
	const length = collection.length;
	for (let i = 0; i < length; i++) {
		const value = collection[i];
		if (predicate(value, i, collection)) result.push(value);
	}
	return result;
}
exports.filter = filter;
