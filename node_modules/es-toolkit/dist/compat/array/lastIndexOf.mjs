import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { toInteger } from "../util/toInteger.mjs";
// src/compat/array/lastIndexOf.ts
function lastIndexOf(array, searchElement, fromIndex) {
	if (!isArrayLike(array) || array.length === 0) return -1;
	const length = array.length;
	let index = fromIndex === void 0 ? length - 1 : toInteger(fromIndex);
	if (fromIndex !== void 0) index = index < 0 ? Math.max(length + index, 0) : Math.min(index, length - 1);
	if (Number.isNaN(searchElement)) {
		for (let i = index; i >= 0; i--) if (Number.isNaN(array[i])) return i;
		return -1;
	}
	for (let i = index; i >= 0; i--) if (array[i] === searchElement) return i;
	return -1;
}
export { lastIndexOf };
