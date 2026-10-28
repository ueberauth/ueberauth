import { isPrimitive } from "../../predicate/isPrimitive.mjs";
import { isTypedArray } from "../../predicate/isTypedArray.mjs";
// src/compat/_internal/baseClone.ts
/**
* A copy of `clone` from `es-toolkit/object` that does not rely on `AggregateError`,
* which is not available on ES2015 engines, so that `es-toolkit/compat` runs on Node.js 6
* without changing the main library.
*
* @template T - The type of the value.
* @param obj - The value to clone.
* @returns A shallow clone of the given value.
*/
function baseClone(obj) {
	if (isPrimitive(obj)) return obj;
	if (Array.isArray(obj) || isTypedArray(obj) || obj instanceof ArrayBuffer || typeof SharedArrayBuffer !== "undefined" && obj instanceof SharedArrayBuffer) return obj.slice(0);
	const prototype = Object.getPrototypeOf(obj);
	if (prototype == null) return Object.assign(Object.create(prototype), obj);
	const Constructor = prototype.constructor;
	if (obj instanceof Date || obj instanceof Map || obj instanceof Set) return new Constructor(obj);
	if (obj instanceof RegExp) {
		const newRegExp = new Constructor(obj);
		newRegExp.lastIndex = obj.lastIndex;
		return newRegExp;
	}
	if (obj instanceof DataView) return new Constructor(obj.buffer.slice(0));
	if (obj instanceof Error) {
		let newError;
		if (typeof AggregateError !== "undefined" && obj instanceof AggregateError) newError = new Constructor(obj.errors, obj.message, { cause: obj.cause });
		else newError = new Constructor(obj.message, { cause: obj.cause });
		newError.stack = obj.stack;
		Object.assign(newError, obj);
		return newError;
	}
	if (typeof File !== "undefined" && obj instanceof File) return new Constructor([obj], obj.name, {
		type: obj.type,
		lastModified: obj.lastModified
	});
	if (typeof obj === "object") {
		const newObject = Object.create(prototype);
		return Object.assign(newObject, obj);
	}
	return obj;
}
export { baseClone };
