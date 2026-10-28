const require_isIterable = require("../../predicate/isIterable.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_objectValues = require("../_internal/objectValues.js");
const require_isMap = require("../predicate/isMap.js");
const require_isSet = require("../predicate/isSet.js");
// src/compat/util/toArray.ts
/**
* Converts a value to an array.
*
* @param value - The value to convert.
* @returns Returns the converted array.
*
* @example
* toArray({ 'a': 1, 'b': 2 }) // => [1,2]
* toArray('abc') // => ['a', 'b', 'c']
* toArray(1) // => []
* toArray(null) // => []
*/
function toArray(value) {
	if (value == null) return [];
	if (require_isArrayLike.isArrayLike(value) || require_isMap.isMap(value) || require_isSet.isSet(value)) return Array.from(value);
	if (typeof value === "object") {
		if (require_isIterable.isIterable(value)) return Array.from(value);
		return require_objectValues.objectValues(value);
	}
	return [];
}
exports.toArray = toArray;
