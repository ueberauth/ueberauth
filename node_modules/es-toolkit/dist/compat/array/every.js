const require_identity = require("../../function/identity.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_iteratee = require("../util/iteratee.js");
const require_isIterateeCall = require("../_internal/isIterateeCall.js");
// src/compat/array/every.ts
/**
* Checks if every item in an object has a specific property, where the property name is provided as a PropertyKey.
*
* @template T
* @param collection - The source array or object to check through.
* @param [doesMatch] - The criteria to match. It can be a function, a partial object, a key-value pair, or a property name.
* @param [guard] - Enables use as an iteratee for methods like `_.map`.
* @returns `true` if every property value has the specified property, or `false` if at least one does not match.
*
* @example
* // Using a property name
* const obj = { a: { id: 1, name: 'Alice' }, b: { id: 2, name: 'Bob' } };
* const result = every(obj, 'name');
* console.log(result); // true
*/
function every(collection, doesMatch, guard) {
	var _doesMatch;
	if (!collection) return true;
	if (guard && require_isIterateeCall.isIterateeCall(collection, doesMatch, guard)) doesMatch = void 0;
	const predicate = require_iteratee.iteratee((_doesMatch = doesMatch) !== null && _doesMatch !== void 0 ? _doesMatch : require_identity.identity);
	if (!require_isArrayLike.isArrayLike(collection)) {
		const keys = Object.keys(collection);
		for (let i = 0; i < keys.length; i++) {
			const key = keys[i];
			const value = collection[key];
			if (!predicate(value, key, collection)) return false;
		}
		return true;
	}
	for (let i = 0; i < collection.length; i++) if (!predicate(collection[i], i, collection)) return false;
	return true;
}
exports.every = every;
