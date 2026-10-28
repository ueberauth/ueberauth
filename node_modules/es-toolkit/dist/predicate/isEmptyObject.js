const require_isPlainObject = require("./isPlainObject.js");
// src/predicate/isEmptyObject.ts
/**
* Checks if a value is an empty plain object.
*
* @param value - The value to check.
* @returns True if the value is an empty plain object, otherwise false.
*
* @example
* isEmptyObject({}); // true
* isEmptyObject({ a: 1 }); // false
* isEmptyObject([]); // false
* isEmptyObject(null); // false
*/
function isEmptyObject(value) {
	return require_isPlainObject.isPlainObject(value) && Object.keys(value).length === 0;
}
exports.isEmptyObject = isEmptyObject;
