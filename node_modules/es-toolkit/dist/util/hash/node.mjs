import { hash as hash$1 } from "node:crypto";
// src/util/serialize/serializeBigInt.ts
/**
* Serializes a bigint into a string with an `n` suffix, like a bigint literal.
*
* @param value - The bigint to serialize.
* @returns The serialized string.
*
* @example
* serializeBigInt(123n); // "123n"
*/
function serializeBigInt(value) {
	return `${value}n`;
}
// src/util/serialize/serializeFunction.ts
/**
* Serializes a function into a string of the form `name:source`.
*
* Native functions have no meaningful source, so they are serialized as
* `name:[native]`. The whitespace inside `{ [native code] }` differs between
* engines, so it is matched loosely to keep the output platform independent. For other functions, newlines and their surrounding
* whitespace are collapsed so that formatting differences do not change
* the output.
*
* @param value - The function to serialize.
* @returns The serialized string.
*
* @example
* function sum(a, b) {
*   return a + b;
* }
* serializeFunction(sum); // "sum:function sum(a, b) {return a + b;}"
* serializeFunction(Math.max); // "max:[native]"
*/
function serializeFunction(value) {
	const source = Function.prototype.toString.call(value);
	if (/\{\s*\[native code\]\s*\}$/.test(source)) return `${value.name}:[native]`;
	return `${value.name}:${source.replace(/\s*\n\s*/g, "")}`;
}
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
// src/util/serialize/compareValues.ts
/**
* Compares two values for sorting `Set` values and `Map` keys.
*
* The comparison is a total order, so the sorted result does not depend on
* the insertion order. Values are grouped by type: strings first, then
* numbers and bigints, then everything else. Strings are compared by code
* unit. Numbers and bigints are compared numerically with each other;
* `NaN` sorts after every other number, and a number sorts before a bigint
* of the same value. Every other value is compared by the code unit order
* of its serialized string.
*
* @param a - The first value to compare.
* @param b - The second value to compare.
* @param refs - The circular reference context shared with the surrounding serialization.
* @returns A negative number if `a` sorts before `b`, a positive number if
*   `a` sorts after `b`, and `0` if they are equal.
*/
function compareValues(a, b, refs) {
	const rankA = getTypeRank(a);
	const rankB = getTypeRank(b);
	if (rankA !== rankB) return rankA - rankB;
	if (typeof a === "string" && typeof b === "string") return compareStrings(a, b);
	if (rankA === NUMERIC_RANK) return compareNumeric(a, b);
	return compareStrings(serializeValue(a, refs), serializeValue(b, refs));
}
const STRING_RANK = 0;
const NUMERIC_RANK = 1;
const OTHER_RANK = 2;
function getTypeRank(value) {
	switch (typeof value) {
		case "string": return STRING_RANK;
		case "number":
		case "bigint": return NUMERIC_RANK;
		default: return OTHER_RANK;
	}
}
function compareStrings(a, b) {
	if (a === b) return 0;
	return a < b ? -1 : 1;
}
function compareNumeric(a, b) {
	const isNaNA = typeof a === "number" && Number.isNaN(a);
	const isNaNB = typeof b === "number" && Number.isNaN(b);
	if (isNaNA || isNaNB) return Number(isNaNA) - Number(isNaNB);
	if (a < b) return -1;
	if (a > b) return 1;
	if (typeof a === typeof b) return 0;
	return typeof a === "number" ? -1 : 1;
}
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
// src/predicate/isArrayBuffer.ts
/**
* Checks if a given value is `ArrayBuffer`.
*
* This function can also serve as a type predicate in TypeScript, narrowing the type of the argument to `ArrayBuffer`.
*
* @param value The value to check if it is a `ArrayBuffer`.
* @returns Returns `true` if `value` is a `ArrayBuffer`, else `false`.
*
* @example
* const value1 = new ArrayBuffer();
* const value2 = new Array();
* const value3 = new Map();
*
* console.log(isArrayBuffer(value1)); // true
* console.log(isArrayBuffer(value2)); // false
* console.log(isArrayBuffer(value3)); // false
*/
function isArrayBuffer(value) {
	return value instanceof ArrayBuffer;
}
// src/predicate/isDate.ts
/**
* Checks if `value` is a Date object.
*
* @param value The value to check.
* @returns Returns `true` if `value` is a Date object, `false` otherwise.
*
* @example
* const value1 = new Date();
* const value2 = '2024-01-01';
*
* console.log(isDate(value1)); // true
* console.log(isDate(value2)); // false
*/
function isDate(value) {
	return value instanceof Date;
}
// src/predicate/isError.ts
/**
* Checks if `value` is an Error object.
*
* @param value The value to check.
* @returns Returns `true` if `value` is an Error object, `false` otherwise.
*
* @example
* ```typescript
* console.log(isError(new Error())); // true
* console.log(isError('Error')); // false
* console.log(isError({ name: 'Error', message: '' })); // false
* ```
*/
function isError(value) {
	return value instanceof Error;
}
// src/predicate/isMap.ts
/**
* Checks if a given value is `Map`.
*
* This function can also serve as a type predicate in TypeScript, narrowing the type of the argument to `Map`.
*
* @param value The value to check if it is a `Map`.
* @returns Returns `true` if `value` is a `Map`, else `false`.
*
* @example
* const value1 = new Map();
* const value2 = new Set();
* const value3 = new WeakMap();
*
* console.log(isMap(value1)); // true
* console.log(isMap(value2)); // false
* console.log(isMap(value3)); // false
*/
function isMap(value) {
	return value instanceof Map;
}
// src/predicate/isPlainObject.ts
/**
* Checks if a given value is a plain object.
*
* @param value - The value to check.
* @returns True if the value is a plain object, otherwise false.
*
* @example
* ```typescript
* // ✅👇 True
*
* isPlainObject({ });                       // ✅
* isPlainObject({ key: 'value' });          // ✅
* isPlainObject({ key: new Date() });       // ✅
* isPlainObject(new Object());              // ✅
* isPlainObject(Object.create(null));       // ✅
* isPlainObject({ nested: { key: true} });  // ✅
* isPlainObject(new Proxy({}, {}));         // ✅
* isPlainObject({ [Symbol('tag')]: 'A' });  // ✅
*
* // ✅👇 (cross-realms, node context, workers, ...)
* const runInNewContext = await import('node:vm').then(
*     (mod) => mod.runInNewContext
* );
* isPlainObject(runInNewContext('({})'));   // ✅
*
* // ❌👇 False
*
* class Test { };
* isPlainObject(new Test())           // ❌
* isPlainObject(10);                  // ❌
* isPlainObject(null);                // ❌
* isPlainObject('hello');             // ❌
* isPlainObject([]);                  // ❌
* isPlainObject(new Date());          // ❌
* isPlainObject(new Uint8Array([1])); // ❌
* isPlainObject(Buffer.from('ABC'));  // ❌
* isPlainObject(Promise.resolve({})); // ❌
* isPlainObject(Object.create({}));   // ❌
* isPlainObject(new (class Cls {}));  // ❌
* isPlainObject(globalThis);          // ❌,
* ```
*/
function isPlainObject(value) {
	if (!value || typeof value !== "object") return false;
	const proto = Object.getPrototypeOf(value);
	if (!(proto === null || proto === Object.prototype || Object.getPrototypeOf(proto) === null)) return false;
	return Object.prototype.toString.call(value) === "[object Object]";
}
// src/predicate/isRegExp.ts
/**
* Checks if `value` is a RegExp.
*
* @param value The value to check.
* @returns Returns `true` if `value` is a RegExp, `false` otherwise.
*
* @example
* const value1 = /abc/;
* const value2 = '/abc/';
*
* console.log(isRegExp(value1)); // true
* console.log(isRegExp(value2)); // false
*/
function isRegExp(value) {
	return value instanceof RegExp;
}
// src/predicate/isSet.ts
/**
* Checks if a given value is `Set`.
*
* This function can also serve as a type predicate in TypeScript, narrowing the type of the argument to `Set`.
*
* @param value The value to check if it is a `Set`.
* @returns Returns `true` if `value` is a `Set`, else `false`.
*
* @example
* const value1 = new Set();
* const value2 = new Map();
* const value3 = new WeakSet();
*
* console.log(isSet(value1)); // true
* console.log(isSet(value2)); // false
* console.log(isSet(value3)); // false
*/
function isSet(value) {
	return value instanceof Set;
}
// src/predicate/isTypedArray.ts
/**
* Checks if a value is a TypedArray.
* @param x The value to check.
* @returns Returns true if `x` is a TypedArray, false otherwise.
*
* @example
* const arr = new Uint8Array([1, 2, 3]);
* isTypedArray(arr); // true
*
* const regularArray = [1, 2, 3];
* isTypedArray(regularArray); // false
*
* const buffer = new ArrayBuffer(16);
* isTypedArray(buffer); // false
*/
function isTypedArray(x) {
	return ArrayBuffer.isView(x) && !(x instanceof DataView);
}
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
// src/util/serialize/serializeSymbol.ts
/**
* Serializes a symbol into a string using its description.
*
* The description is quoted like any other string, so a symbol without a
* description (`Symbol()`) is distinguishable from one with an empty
* description (`Symbol('')`). Note that two different symbols with the same
* description still serialize to the same string, since a symbol's identity
* cannot be captured in a string.
*
* @param value - The symbol to serialize.
* @returns The serialized string.
*
* @example
* serializeSymbol(Symbol('test')); // "Symbol('test')"
* serializeSymbol(Symbol()); // "Symbol()"
*/
function serializeSymbol(value) {
	return value.description === void 0 ? "Symbol()" : `Symbol(${serializeString(value.description)})`;
}
// src/util/serialize/serialize.ts
/**
* Serializes any value into a stable string.
*
* Two values with the same structure always serialize to the same string,
* regardless of key insertion order, so the output is suitable for hashing,
* cache keys, and change detection. It is not designed for security purposes;
* intentional collisions can be crafted from user input.
*
* Plain object keys, `Map` keys, and `Set` values are sorted, so the output
* does not depend on insertion order. String keys are always quoted, so a
* string key never collides with a key of another type. Circular references
* are serialized as `#ref{n}` back-references, where `n` is the order in
* which the object was first visited.
*
* Objects that cannot be serialized meaningfully, such as `Promise`, `WeakMap`,
* or `Blob`, throw a `TypeError`.
*
* @param value - The value to serialize.
* @returns The serialized string.
* @throws {TypeError} If the value contains an object that cannot be serialized.
*
* @example
* serialize({ b: 2, a: 1 }); // "{'a':1,'b':2}"
* serialize([1, 2n, 'a', { k: 1 }]); // "[1,2n,'a',{'k':1}]"
* serialize(new Set([3, 1, 2])); // "Set[1,2,3]"
* serialize(new Date(0)); // "Date('1970-01-01T00:00:00.000Z')"
*
* const obj = {};
* obj.self = obj;
* serialize(obj); // "{'self':#ref0}"
*/
function serialize(value) {
	return serializeValue(value, /* @__PURE__ */ new Map());
}
/**
* Serializes a value with a shared circular reference context.
*
* @param value - The value to serialize.
* @param refs - Objects that are being serialized or have been serialized,
*   mapped to their back-reference placeholder or completed serialization.
* @returns The serialized string.
*/
function serializeValue(value, refs) {
	switch (typeof value) {
		case "string": return serializeString(value);
		case "number": return serializeNumber(value);
		case "bigint": return serializeBigInt(value);
		case "symbol": return serializeSymbol(value);
		case "function": return serializeFunction(value);
		case "object": return serializeObject(value, refs);
		case "boolean": return String(value);
		case "undefined": return "undefined";
	}
}
// src/util/hash/node.ts
/**
* Hashes any value into a stable 43-character string.
*
* The value is serialized with `serialize`, so two values with the same
* structure always hash to the same string regardless of key insertion
* order, and then digested with SHA-256 and encoded in Base64URL format.
*
* The hash is stable across platforms, but it is not designed for security
* purposes; intentional collisions can be crafted from user input.
*
* This entry uses the native `node:crypto` implementation and requires
* Node.js 20.12 or later; in browsers, a pure JavaScript implementation
* with identical output is used instead.
*
* @param value - The value to hash.
* @returns The Base64URL-encoded SHA-256 hash of the serialized value.
* @throws {TypeError} If the value contains an object that cannot be serialized.
*
* @example
* hash({ b: 2, a: 1 }) === hash({ a: 1, b: 2 }); // true
* hash([1, 2, 3]); // "phXuruId5Red4IDejDBSyNqQEThAa6ccOMAyhF99VPQ" (43 characters)
*/
function hash(value) {
	return hash$1("sha256", serialize(value), "base64url");
}
export { hash };
