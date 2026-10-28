const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_toInteger = require("../util/toInteger.js");
// src/compat/array/lastIndexOf.ts
function lastIndexOf(array, searchElement, fromIndex) {
	if (!require_isArrayLike.isArrayLike(array) || array.length === 0) return -1;
	const length = array.length;
	let index = fromIndex === void 0 ? length - 1 : require_toInteger.toInteger(fromIndex);
	if (fromIndex !== void 0) index = index < 0 ? Math.max(length + index, 0) : Math.min(index, length - 1);
	if (Number.isNaN(searchElement)) {
		for (let i = index; i >= 0; i--) if (Number.isNaN(array[i])) return i;
		return -1;
	}
	for (let i = index; i >= 0; i--) if (array[i] === searchElement) return i;
	return -1;
}
exports.lastIndexOf = lastIndexOf;
