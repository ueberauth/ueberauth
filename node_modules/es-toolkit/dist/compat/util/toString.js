const require_baseToString = require("../_internal/baseToString.js");
// src/compat/util/toString.ts
/**
* Converts `value` to a string.
*
* An empty string is returned for `null` and `undefined` values.
* The sign of `-0` is preserved.
*
* @param value - The value to convert.
* @returns Returns the converted string.
*
* @example
* toString(null) // returns ''
* toString(undefined) // returns ''
* toString(-0) // returns '-0'
* toString([1, 2, -0]) // returns '1,2,-0'
* toString([Symbol('a'), Symbol('b')]) // returns 'Symbol(a),Symbol(b)'
*/
function toString(value) {
	if (value == null) return "";
	return require_baseToString.baseToString(value);
}
exports.toString = toString;
