import { isTypedArray } from "../../predicate/isTypedArray.mjs";
import { isPlainObject } from "../../predicate/isPlainObject.mjs";
import { isArrayBuffer } from "../../predicate/isArrayBuffer.mjs";
import { isDate } from "../../predicate/isDate.mjs";
import { isError } from "../../predicate/isError.mjs";
import { isMap } from "../../predicate/isMap.mjs";
import { isRegExp } from "../../predicate/isRegExp.mjs";
import { isSet } from "../../predicate/isSet.mjs";
import { compareValues } from "./compareValues.mjs";
import { serializeString } from "./serializeString.mjs";
import { serializePlainObject } from "./serializePlainObject.mjs";
import { serializeValue } from "./serialize.mjs";
// src/util/serialize/serializeObject.ts
/**
* Serializes an object, handling circular references and repeated references.
*
* The first time an object is visited, it is registered as `#ref{n}` where `n`
* is the visit order; if the object is reached again while it is still being
* serialized, the back-reference is emitted instead. Once completed, the
* serialized string is memoized so that repeated references serialize
* in constant time.
*
* @param value - The object to serialize, or `null`.
* @param refs - The circular reference context shared across one serialization.
* @returns The serialized string.
* @throws {TypeError} If the object cannot be serialized.
*/
function serializeObject(value, refs) {
	if (value === null) return "null";
	const cached = refs.get(value);
	if (cached !== void 0) return cached;
	refs.set(value, `#ref${refs.size}`);
	const result = serializeObjectImpl(value, refs);
	refs.set(value, result);
	return result;
}
function serializeObjectImpl(value, refs) {
	if (Array.isArray(value)) return serializeArray(value, refs);
	if (isPlainObject(value)) return serializePlainObject(value, refs);
	if (isDate(value)) return Number.isNaN(value.getTime()) ? "Date(null)" : `Date(${serializeString(value.toISOString())})`;
	if (isRegExp(value)) return `RegExp(${value.toString()})`;
	if (isSet(value)) return `Set${serializeArray(Array.from(value).sort((a, b) => compareValues(a, b, refs)), refs)}`;
	if (isMap(value)) return serializeEntries("Map", value.entries(), refs);
	if (isTypedArray(value)) {
		const name = value[Symbol.toStringTag];
		if (name === "BigInt64Array" || name === "BigUint64Array") return `${name}[${value.join("n,")}${value.length > 0 ? "n" : ""}]`;
		return `${name}[${value.join(",")}]`;
	}
	if (isArrayBuffer(value)) return `ArrayBuffer[${new Uint8Array(value).join(",")}]`;
	if (isError(value)) return `Error(${value.name}: ${serializeString(value.message)})`;
	const tag = Object.prototype.toString.call(value).slice(8, -1);
	if (tag === "Object") return serializeClassInstance(value, refs);
	if (typeof value.entries === "function") return serializeEntries(tag, value.entries(), refs);
	throw new TypeError(`Cannot serialize ${tag}`);
}
function serializeArray(array, refs) {
	let result = "[";
	for (let i = 0; i < array.length; i++) {
		if (i > 0) result += ",";
		result += serializeValue(array[i], refs);
	}
	return result + "]";
}
function serializeEntries(tag, entries, refs) {
	const sortedEntries = Array.from(entries).sort((a, b) => compareValues(a[0], b[0], refs));
	let result = `${tag}{`;
	for (let i = 0; i < sortedEntries.length; i++) {
		const [key, value] = sortedEntries[i];
		if (i > 0) result += ",";
		result += `${serializeValue(key, refs)}:${serializeValue(value, refs)}`;
	}
	return result + "}";
}
function serializeClassInstance(value, refs) {
	const constructor = value.constructor;
	const name = constructor === Object || constructor === void 0 ? "" : constructor.name;
	if ("toJSON" in value && typeof value.toJSON === "function") {
		const json = value.toJSON();
		if (json !== null && typeof json === "object") return name + serializeObject(json, refs);
		return `${name}(${serializeValue(json, refs)})`;
	}
	return name + serializePlainObject(value, refs);
}
export { serializeObject };
