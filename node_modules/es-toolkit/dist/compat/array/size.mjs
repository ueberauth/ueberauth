import { isNil } from "../../predicate/isNil.mjs";
import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { regexMultiByte } from "../_internal/regexMultiByte.mjs";
import { unicodeSize } from "../_internal/unicodeSize.mjs";
// src/compat/array/size.ts
function size(target) {
	if (isNil(target)) return 0;
	if (typeof target === "string") return regexMultiByte.test(target) ? unicodeSize(target) : target.length;
	if (isArrayLike(target)) return target.length;
	if (target instanceof Map || target instanceof Set) return target.size;
	return Object.keys(target).length;
}
export { size };
