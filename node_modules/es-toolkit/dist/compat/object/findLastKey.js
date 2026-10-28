const require_isObject = require("../predicate/isObject.js");
const require_iteratee = require("../util/iteratee.js");
const require_identity = require("../function/identity.js");
// src/compat/object/findLastKey.ts
/**
* Finds the key of the last element that matches the given predicate.
*
* This function determines the type of the predicate and delegates the search
* to the appropriate helper function. It supports predicates as functions, objects,
* arrays, or strings.
*
* @template T - The type of the object.
* @param obj - The object to inspect.
* @param predicate - The predicate to match.
* @returns Returns the key of the matched element, else `undefined`.
*/
function findLastKey(obj, predicate) {
	if (!require_isObject.isObject(obj)) return;
	const iteratee$1 = require_iteratee.iteratee(predicate !== null && predicate !== void 0 ? predicate : require_identity.identity);
	const keys = Object.keys(obj);
	for (let i = keys.length - 1; i >= 0; i--) {
		const key = keys[i];
		if (iteratee$1(obj[key], key, obj)) return key;
	}
}
exports.findLastKey = findLastKey;
