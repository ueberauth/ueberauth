// src/util/serialize/serializeString.ts
/**
* Serializes a string into a single-quoted string literal.
*
* The string is not escaped; the output is intended for hashing and
* change detection, not for parsing or re-evaluation.
*
* @param value - The string to serialize.
* @returns The serialized string.
*
* @example
* serializeString('abc'); // "'abc'"
*/
function serializeString(value) {
	return `'${value}'`;
}
exports.serializeString = serializeString;
