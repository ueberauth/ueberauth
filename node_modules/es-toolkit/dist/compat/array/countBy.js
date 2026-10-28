const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_objectValues = require("../_internal/objectValues.js");
const require_iteratee = require("../util/iteratee.js");
// src/compat/array/countBy.ts
function countBy(collection, iteratee$1) {
	if (collection == null) return {};
	const array = require_isArrayLike.isArrayLike(collection) ? Array.from(collection) : require_objectValues.objectValues(collection);
	const mapper = require_iteratee.iteratee(iteratee$1 !== null && iteratee$1 !== void 0 ? iteratee$1 : void 0);
	const result = Object.create(null);
	for (let i = 0; i < array.length; i++) {
		var _result$key;
		const item = array[i];
		const key = mapper(item);
		result[key] = ((_result$key = result[key]) !== null && _result$key !== void 0 ? _result$key : 0) + 1;
	}
	return Object.setPrototypeOf(result, Object.prototype);
}
exports.countBy = countBy;
