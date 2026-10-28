const require_uniqBy = require("../../array/uniqBy.js");
const require_ary = require("../../function/ary.js");
const require_identity = require("../../function/identity.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_iteratee = require("../util/iteratee.js");
const require_normalizeZero = require("../_internal/normalizeZero.js");
// src/compat/array/uniqBy.ts
function uniqBy(array, iteratee$1 = require_identity.identity) {
	if (!require_isArrayLike.isArrayLike(array)) return [];
	return require_uniqBy.uniqBy(Array.from(array), require_ary.ary(require_iteratee.iteratee(iteratee$1), 1)).map(require_normalizeZero.normalizeZero);
}
exports.uniqBy = uniqBy;
