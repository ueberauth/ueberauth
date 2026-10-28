import { isPrimitive } from "../../predicate/isPrimitive.mjs";
import { getSymbols } from "../_internal/getSymbols.mjs";
import { getTag } from "../_internal/getTag.mjs";
import { argumentsTag, arrayBufferTag, arrayTag, booleanTag, dataViewTag, dateTag, float32ArrayTag, float64ArrayTag, int16ArrayTag, int32ArrayTag, int8ArrayTag, mapTag, numberTag, objectTag, regexpTag, setTag, stringTag, symbolTag, uint16ArrayTag, uint32ArrayTag, uint8ArrayTag, uint8ClampedArrayTag } from "../_internal/tags.mjs";
import { hasOwn } from "../_internal/hasOwn.mjs";
import { isBuffer } from "../predicate/isBuffer.mjs";
import { isTypedArray } from "../predicate/isTypedArray.mjs";
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
	if (isPrimitive(valueToClone)) return valueToClone;
	if (stack.has(valueToClone)) return stack.get(valueToClone);
	if (Array.isArray(valueToClone)) {
		const result = new Array(valueToClone.length);
		stack.set(valueToClone, result);
		for (let i = 0; i < valueToClone.length; i++) result[i] = cloneDeepWithImpl(valueToClone[i], i, objectToClone, stack, customizer);
		if (hasOwn(valueToClone, "index")) result.index = valueToClone.index;
		if (hasOwn(valueToClone, "input")) result.input = valueToClone.input;
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
	if (isBuffer(valueToClone)) return valueToClone.subarray();
	if (isTypedArray(valueToClone)) {
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
	const tag = getTag(valueToClone);
	if (tag === "[object Error]") {
		if (valueToClone === objectToClone) return {};
		return valueToClone;
	}
	switch (tag) {
		case numberTag:
		case stringTag:
		case booleanTag: {
			const result = new valueToClone.constructor(valueToClone.valueOf());
			stack.set(valueToClone, result);
			copyProperties(result, valueToClone, objectToClone, stack, customizer);
			return result;
		}
		case argumentsTag: {
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
	const keys = [...Object.keys(source), ...getSymbols(source)];
	for (let i = 0; i < keys.length; i++) {
		const key = keys[i];
		const descriptor = Object.getOwnPropertyDescriptor(target, key);
		if (descriptor == null || descriptor.writable) target[key] = cloneDeepWithImpl(source[key], key, objectToClone, stack, customizer);
	}
}
function isCloneableObject(tag) {
	switch (tag) {
		case argumentsTag:
		case arrayTag:
		case arrayBufferTag:
		case dataViewTag:
		case booleanTag:
		case dateTag:
		case float32ArrayTag:
		case float64ArrayTag:
		case int8ArrayTag:
		case int16ArrayTag:
		case int32ArrayTag:
		case mapTag:
		case numberTag:
		case objectTag:
		case regexpTag:
		case setTag:
		case stringTag:
		case symbolTag:
		case uint8ArrayTag:
		case uint8ClampedArrayTag:
		case uint16ArrayTag:
		case uint32ArrayTag: return true;
		default: return false;
	}
}
export { cloneDeepWith };
