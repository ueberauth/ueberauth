const require_identity = require("../../function/identity.js");
const require_range = require("../../math/range.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_iteratee = require("../util/iteratee.js");
const require_toInteger = require("../util/toInteger.js");
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
function find(collection, _doesMatch = require_identity.identity, fromIndex = 0) {
	if (!collection) return;
	const doesMatch = require_iteratee.iteratee(_doesMatch);
	const keys = require_isArrayLike.isArrayLike(collection) ? require_range.range(0, collection.length) : Object.keys(collection);
	fromIndex = require_toInteger.toInteger(fromIndex);
	if (!fromIndex) fromIndex = 0;
	if (fromIndex < 0) fromIndex = Math.max(keys.length + fromIndex, 0);
	for (let i = fromIndex; i < keys.length; i++) {
		const key = keys[i];
		const value = collection[key];
		if (doesMatch(value, key, collection)) return value;
	}
}
exports.find = find;
