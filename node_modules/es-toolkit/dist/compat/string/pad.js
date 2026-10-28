const require_toString = require("../util/toString.js");
const require_toInteger = require("../util/toInteger.js");
const require_createPadding = require("../_internal/createPadding.js");
// src/compat/string/pad.ts
/**
* Pads string on the left and right sides if it's shorter than length. Padding characters are truncated if they can't be evenly divided by length.
* If the length is less than or equal to the original string's length, or if the padding character is an empty string, the original string is returned unchanged.
*
* @param str - The string to pad.
* @param [length] - The length of the resulting string once padded.
* @param [chars] - The character(s) to use for padding.
* @returns The padded string, or the original string if padding is not required.
*
* @example
* const result1 = pad('abc', 8);         // result will be '  abc   '
* const result2 = pad('abc', 8, '_-');   // result will be '_-abc_-_'
* const result3 = pad('abc', 3);         // result will be 'abc'
* const result4 = pad('abc', 2);         // result will be 'abc'
*
*/
function pad(str, length = 0, chars = " ") {
	const value = require_toString.toString(str);
	const targetLength = require_toInteger.toInteger(length);
	const strLength = require_createPadding.stringSize(value);
	if (targetLength <= strLength) return value;
	const mid = (targetLength - strLength) / 2;
	const padChars = `${chars}`;
	return require_createPadding.createPadding(Math.floor(mid), padChars) + value + require_createPadding.createPadding(Math.ceil(mid), padChars);
}
exports.pad = pad;
