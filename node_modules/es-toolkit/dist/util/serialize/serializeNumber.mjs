// src/util/serialize/serializeNumber.ts
/**
* Serializes a number into a string.
*
* `-0` is serialized as `0`, and `NaN` and `Infinity` are serialized
* as their string representations.
*
* @param value - The number to serialize.
* @returns The serialized string.
*
* @example
* serializeNumber(1); // "1"
* serializeNumber(-0); // "0"
* serializeNumber(NaN); // "NaN"
* serializeNumber(Infinity); // "Infinity"
*/
function serializeNumber(value) {
	return String(value);
}
export { serializeNumber };
