const require_isPrimitive = require("../../predicate/isPrimitive.js");
const require_getSymbols = require("../_internal/getSymbols.js");
const require_getTag = require("../_internal/getTag.js");
const require_tags = require("../_internal/tags.js");
const require_hasOwn = require("../_internal/hasOwn.js");
const require_isBuffer = require("../predicate/isBuffer.js");
const require_isTypedArray = require("../predicate/isTypedArray.js");
// src/compat/object/cloneDeepWith.ts
/**
* Creates a deep clone of the given object using a customizer function.
*
* @template T - The type of the object.
* @param obj - The object to clone.
* @param [cloneValue] - A function to customize the cloning process.
* @returns A deep clone of the given object.
*
* @example
* // Clone a primitive value
* const num = 29;
* const clonedNum = cloneDeepWith(num);
* console.log(clonedNum); // 29
* console.log(clonedNum === num); // true
*
* @example
* // Clone an object with a customizer
* const obj = { a: 1, b: 2 };
* const clonedObj = cloneDeepWith(obj, (value) => {
*   if (typeof value === 'number') {
*     return value * 2; // Double the number
*   }
* });
* console.log(clonedObj); // { a: 2, b: 4 }
* console.log(clonedObj === obj); // false
*
* @example
* // Clone an array with a customizer
* const arr = [1, 2, 3];
* const clonedArr = cloneDeepWith(arr, (value) => {
*   if (typeof value === 'number') {
*     return value + 1; // Increment each number
*   }
* });
* console.log(clonedArr); // [2, 3, 4]
* console.log(clonedArr === arr); // false
*/
function cloneDeepWith(obj, customizer) {
	return cloneDeepWithImpl(obj, void 0, obj, /* @__PURE__ */ new Map(), customizer);
}
function cloneDeepWithImpl(valueToClone, keyToClone, objectToClone, stack, customizer) {
	if (customizer != null) {
		const cloned = customizer(valueToClone, keyToClone, objectToClone, stack);
		if (cloned !== void 0) return cloned;
	}
	if (require_isPrimitive.isPrimitive(valueToClone)) return valueToClone;
	if (stack.has(valueToClone)) return stack.get(valueToClone);
	if (Array.isArray(valueToClone)) {
		const result = new Array(valueToClone.length);
		stack.set(valueToClone, result);
		for (let i = 0; i < valueToClone.length; i++) result[i] = cloneDeepWithImpl(valueToClone[i], i, objectToClone, stack, customizer);
		if (require_hasOwn.hasOwn(valueToClone, "index")) result.index = valueToClone.index;
		if (require_hasOwn.hasOwn(valueToClone, "input")) result.input = valueToClone.input;
		return result;
	}
	if (valueToClone instanceof Date) return new Date(valueToClone.getTime());
	if (valueToClone instanceof RegExp) {
		const result = new RegExp(valueToClone.source, valueToClone.flags);
		result.lastIndex = valueToClone.lastIndex;
		return result;
	}
	if (valueToClone instanceof Map) {
		const result = /* @__PURE__ */ new Map();
		stack.set(valueToClone, result);
		valueToClone.forEach((value, key) => {
			result.set(key, cloneDeepWithImpl(value, key, objectToClone, stack, customizer));
		});
		return result;
	}
	if (valueToClone instanceof Set) {
		const result = /* @__PURE__ */ new Set();
		stack.set(valueToClone, result);
		valueToClone.forEach((value) => {
			result.add(cloneDeepWithImpl(value, void 0, objectToClone, stack, customizer));
		});
		return result;
	}
	if (require_isBuffer.isBuffer(valueToClone)) return valueToClone.subarray();
	if (require_isTypedArray.isTypedArray(valueToClone)) {
		const result = new (Object.getPrototypeOf(valueToClone)).constructor(valueToClone.length);
		stack.set(valueToClone, result);
		for (let i = 0; i < valueToClone.length; i++) result[i] = cloneDeepWithImpl(valueToClone[i], i, objectToClone, stack, customizer);
		return result;
	}
	if (valueToClone instanceof ArrayBuffer || typeof SharedArrayBuffer !== "undefined" && valueToClone instanceof SharedArrayBuffer) return valueToClone.slice(0);
	if (valueToClone instanceof DataView) {
		const result = new DataView(valueToClone.buffer.slice(0), valueToClone.byteOffset, valueToClone.byteLength);
		stack.set(valueToClone, result);
		copyProperties(result, valueToClone, objectToClone, stack, customizer);
		return result;
	}
	if (typeof File !== "undefined" && valueToClone instanceof File) {
		const result = new File([valueToClone], valueToClone.name, { type: valueToClone.type });
		stack.set(valueToClone, result);
		copyProperties(result, valueToClone, objectToClone, stack, customizer);
		return result;
	}
	if (typeof Blob !== "undefined" && valueToClone instanceof Blob) {
		const result = new Blob([valueToClone], { type: valueToClone.type });
		stack.set(valueToClone, result);
		copyProperties(result, valueToClone, objectToClone, stack, customizer);
		return result;
	}
	const tag = require_getTag.getTag(valueToClone);
	if (tag === "[object Error]") {
		if (valueToClone === objectToClone) return {};
		return valueToClone;
	}
	switch (tag) {
		case require_tags.numberTag:
		case require_tags.stringTag:
		case require_tags.booleanTag: {
			const result = new valueToClone.constructor(valueToClone.valueOf());
			stack.set(valueToClone, result);
			copyProperties(result, valueToClone, objectToClone, stack, customizer);
			return result;
		}
		case require_tags.argumentsTag: {
			const result = {};
			stack.set(valueToClone, result);
			copyProperties(result, valueToClone, objectToClone, stack, customizer);
			result.length = valueToClone.length;
			result[Symbol.iterator] = valueToClone[Symbol.iterator];
			return result;
		}
	}
	if (typeof valueToClone === "object" && isCloneableObject(tag)) {
		const result = tag === "[object Object]" && typeof valueToClone.constructor !== "function" ? {} : Object.create(Object.getPrototypeOf(valueToClone));
		stack.set(valueToClone, result);
		copyProperties(result, valueToClone, objectToClone, stack, customizer);
		return result;
	}
	return valueToClone;
}
function copyProperties(target, source, objectToClone, stack, customizer) {
	const keys = [...Object.keys(source), ...require_getSymbols.getSymbols(source)];
	for (let i = 0; i < keys.length; i++) {
		const key = keys[i];
		const descriptor = Object.getOwnPropertyDescriptor(target, key);
		if (descriptor == null || descriptor.writable) target[key] = cloneDeepWithImpl(source[key], key, objectToClone, stack, customizer);
	}
}
function isCloneableObject(tag) {
	switch (tag) {
		case require_tags.argumentsTag:
		case require_tags.arrayTag:
		case require_tags.arrayBufferTag:
		case require_tags.dataViewTag:
		case require_tags.booleanTag:
		case require_tags.dateTag:
		case require_tags.float32ArrayTag:
		case require_tags.float64ArrayTag:
		case require_tags.int8ArrayTag:
		case require_tags.int16ArrayTag:
		case require_tags.int32ArrayTag:
		case require_tags.mapTag:
		case require_tags.numberTag:
		case require_tags.objectTag:
		case require_tags.regexpTag:
		case require_tags.setTag:
		case require_tags.stringTag:
		case require_tags.symbolTag:
		case require_tags.uint8ArrayTag:
		case require_tags.uint8ClampedArrayTag:
		case require_tags.uint16ArrayTag:
		case require_tags.uint32ArrayTag: return true;
		default: return false;
	}
}
exports.cloneDeepWith = cloneDeepWith;
