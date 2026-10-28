const require_isTypedArray = require("../../predicate/isTypedArray.js");
const require_isPlainObject = require("../../predicate/isPlainObject.js");
const require_isArrayBuffer = require("../../predicate/isArrayBuffer.js");
const require_isDate = require("../../predicate/isDate.js");
const require_isError = require("../../predicate/isError.js");
const require_isMap = require("../../predicate/isMap.js");
const require_isRegExp = require("../../predicate/isRegExp.js");
const require_isSet = require("../../predicate/isSet.js");
const require_compareValues = require("./compareValues.js");
const require_serializeString = require("./serializeString.js");
const require_serializePlainObject = require("./serializePlainObject.js");
const require_serialize = require("./serialize.js");
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
	if (require_isPlainObject.isPlainObject(value)) return require_serializePlainObject.serializePlainObject(value, refs);
	if (require_isDate.isDate(value)) return Number.isNaN(value.getTime()) ? "Date(null)" : `Date(${require_serializeString.serializeString(value.toISOString())})`;
	if (require_isRegExp.isRegExp(value)) return `RegExp(${value.toString()})`;
	if (require_isSet.isSet(value)) return `Set${serializeArray(Array.from(value).sort((a, b) => require_compareValues.compareValues(a, b, refs)), refs)}`;
	if (require_isMap.isMap(value)) return serializeEntries("Map", value.entries(), refs);
	if (require_isTypedArray.isTypedArray(value)) {
		const name = value[Symbol.toStringTag];
		if (name === "BigInt64Array" || name === "BigUint64Array") return `${name}[${value.join("n,")}${value.length > 0 ? "n" : ""}]`;
		return `${name}[${value.join(",")}]`;
	}
	if (require_isArrayBuffer.isArrayBuffer(value)) return `ArrayBuffer[${new Uint8Array(value).join(",")}]`;
	if (require_isError.isError(value)) return `Error(${value.name}: ${require_serializeString.serializeString(value.message)})`;
	const tag = Object.prototype.toString.call(value).slice(8, -1);
	if (tag === "Object") return serializeClassInstance(value, refs);
	if (typeof value.entries === "function") return serializeEntries(tag, value.entries(), refs);
	throw new TypeError(`Cannot serialize ${tag}`);
}
function serializeArray(array, refs) {
	let result = "[";
	for (let i = 0; i < array.length; i++) {
		if (i > 0) result += ",";
		result += require_serialize.serializeValue(array[i], refs);
	}
	return result + "]";
}
function serializeEntries(tag, entries, refs) {
	const sortedEntries = Array.from(entries).sort((a, b) => require_compareValues.compareValues(a[0], b[0], refs));
	let result = `${tag}{`;
	for (let i = 0; i < sortedEntries.length; i++) {
		const [key, value] = sortedEntries[i];
		if (i > 0) result += ",";
		result += `${require_serialize.serializeValue(key, refs)}:${require_serialize.serializeValue(value, refs)}`;
	}
	return result + "}";
}
function serializeClassInstance(value, refs) {
	const constructor = value.constructor;
	const name = constructor === Object || constructor === void 0 ? "" : constructor.name;
	if ("toJSON" in value && typeof value.toJSON === "function") {
		const json = value.toJSON();
		if (json !== null && typeof json === "object") return name + serializeObject(json, refs);
		return `${name}(${require_serialize.serializeValue(json, refs)})`;
	}
	return name + require_serializePlainObject.serializePlainObject(value, refs);
}
exports.serializeObject = serializeObject;
