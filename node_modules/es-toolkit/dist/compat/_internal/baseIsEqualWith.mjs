import { getSymbols } from "./getSymbols.mjs";
import { getTag } from "./getTag.mjs";
import { arrayBufferTag, arrayTag, bigInt64ArrayTag, bigUint64ArrayTag, booleanTag, dataViewTag, dateTag, errorTag, float32ArrayTag, float64ArrayTag, functionTag, int16ArrayTag, int32ArrayTag, int8ArrayTag, mapTag, numberTag, objectTag, regexpTag, setTag, stringTag, symbolTag, uint16ArrayTag, uint32ArrayTag, uint8ArrayTag, uint8ClampedArrayTag } from "./tags.mjs";
import { isBuffer } from "../../predicate/isBuffer.mjs";
import { isPlainObject } from "../../predicate/isPlainObject.mjs";
import { eq } from "../util/eq.mjs";
import { hasOwn } from "./hasOwn.mjs";
// src/compat/_internal/baseIsEqualWith.ts
/**
* A copy of `isEqualWith` from `es-toolkit/predicate` that only relies on ES2015 built-ins,
* so that `es-toolkit/compat` runs on Node.js 6 without changing the main library.
*
* @param a - The first value to compare.
* @param b - The second value to compare.
* @param areValuesEqual - A function to customize the comparison.
*   If it returns a boolean, that result will be used. If it returns undefined,
*   the default equality comparison will be used.
* @returns `true` if the values are equal according to the customizer, otherwise `false`.
*/
function baseIsEqualWith(a, b, areValuesEqual) {
	return isEqualWithImpl(a, b, void 0, void 0, void 0, void 0, areValuesEqual);
}
function isEqualWithImpl(a, b, property, aParent, bParent, stack, areValuesEqual) {
	const result = areValuesEqual(a, b, property, aParent, bParent, stack);
	if (result !== void 0) return result;
	if (typeof a === typeof b) switch (typeof a) {
		case "bigint":
		case "string":
		case "boolean":
		case "symbol":
		case "undefined": return a === b;
		case "number": return a === b || Object.is(a, b);
		case "function": return a === b;
		case "object": return areObjectsEqual(a, b, stack, areValuesEqual);
	}
	return areObjectsEqual(a, b, stack, areValuesEqual);
}
function areObjectsEqual(a, b, stack, areValuesEqual) {
	var _stack;
	if (Object.is(a, b)) return true;
	let aTag = getTag(a);
	let bTag = getTag(b);
	if (aTag === "[object Arguments]") aTag = objectTag;
	if (bTag === "[object Arguments]") bTag = objectTag;
	if (aTag !== bTag) return false;
	switch (aTag) {
		case stringTag: return a.toString() === b.toString();
		case numberTag: {
			const x = a.valueOf();
			const y = b.valueOf();
			return eq(x, y);
		}
		case booleanTag:
		case dateTag:
		case symbolTag: return Object.is(a.valueOf(), b.valueOf());
		case regexpTag: return a.source === b.source && a.flags === b.flags;
		case functionTag: return a === b;
	}
	stack = (_stack = stack) !== null && _stack !== void 0 ? _stack : /* @__PURE__ */ new Map();
	const aStack = stack.get(a);
	const bStack = stack.get(b);
	if (aStack != null && bStack != null) return aStack === b;
	stack.set(a, b);
	stack.set(b, a);
	try {
		switch (aTag) {
			case mapTag:
				if (a.size !== b.size) return false;
				for (const [key, value] of a.entries()) if (!b.has(key) || !isEqualWithImpl(value, b.get(key), key, a, b, stack, areValuesEqual)) return false;
				return true;
			case setTag: {
				if (a.size !== b.size) return false;
				const aValues = Array.from(a.values());
				const bValues = Array.from(b.values());
				for (let i = 0; i < aValues.length; i++) {
					const aValue = aValues[i];
					const index = bValues.findIndex((bValue) => {
						return isEqualWithImpl(aValue, bValue, void 0, a, b, stack, areValuesEqual);
					});
					if (index === -1) return false;
					bValues.splice(index, 1);
				}
				return true;
			}
			case arrayTag:
			case uint8ArrayTag:
			case uint8ClampedArrayTag:
			case uint16ArrayTag:
			case uint32ArrayTag:
			case bigUint64ArrayTag:
			case int8ArrayTag:
			case int16ArrayTag:
			case int32ArrayTag:
			case bigInt64ArrayTag:
			case float32ArrayTag:
			case float64ArrayTag:
				if (isBuffer(a) !== isBuffer(b)) return false;
				if (a.length !== b.length) return false;
				for (let i = 0; i < a.length; i++) if (!isEqualWithImpl(a[i], b[i], i, a, b, stack, areValuesEqual)) return false;
				return true;
			case arrayBufferTag:
				if (a.byteLength !== b.byteLength) return false;
				return areObjectsEqual(new Uint8Array(a), new Uint8Array(b), stack, areValuesEqual);
			case dataViewTag:
				if (a.byteLength !== b.byteLength || a.byteOffset !== b.byteOffset) return false;
				return areObjectsEqual(new Uint8Array(a), new Uint8Array(b), stack, areValuesEqual);
			case errorTag: return a.name === b.name && a.message === b.message;
			case objectTag: {
				if (!(areObjectsEqual(a.constructor, b.constructor, stack, areValuesEqual) || isPlainObject(a) && isPlainObject(b))) return false;
				const aKeys = [...Object.keys(a), ...getSymbols(a)];
				const bKeys = [...Object.keys(b), ...getSymbols(b)];
				if (aKeys.length !== bKeys.length) return false;
				for (let i = 0; i < aKeys.length; i++) {
					const propKey = aKeys[i];
					const aProp = a[propKey];
					if (!hasOwn(b, propKey)) return false;
					const bProp = b[propKey];
					if (!isEqualWithImpl(aProp, bProp, propKey, a, b, stack, areValuesEqual)) return false;
				}
				return true;
			}
			default: return false;
		}
	} finally {
		stack.delete(a);
		stack.delete(b);
	}
}
export { baseIsEqualWith };
