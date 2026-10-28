import { serializeString } from "./serializeString.mjs";
import { serializeValue } from "./serialize.mjs";
// src/util/serialize/serializePlainObject.ts
/**
* Serializes the own enumerable string-keyed properties of an object
* into a `{'key':value}` string.
*
* Keys are sorted by code unit so that the output does not depend on
* property insertion order, and always quoted so that a key containing
* `:` or `,` cannot be confused with the surrounding structure. Symbol
* keys and non-enumerable properties are ignored.
*
* @param object - The object to serialize.
* @param refs - The circular reference context shared with the surrounding serialization.
* @returns The serialized string.
*
* @example
* serializePlainObject({ b: 2, a: 1 }, new Map()); // "{'a':1,'b':2}"
*/
function serializePlainObject(object, refs) {
	const keys = Object.keys(object).sort();
	let result = "{";
	for (let i = 0; i < keys.length; i++) {
		const key = keys[i];
		if (i > 0) result += ",";
		result += `${serializeString(key)}:${serializeValue(object[key], refs)}`;
	}
	return result + "}";
}
export { serializePlainObject };
