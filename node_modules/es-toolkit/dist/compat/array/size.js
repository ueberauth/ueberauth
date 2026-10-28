const require_isNil = require("../../predicate/isNil.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_regexMultiByte = require("../_internal/regexMultiByte.js");
const require_unicodeSize = require("../_internal/unicodeSize.js");
// src/compat/array/size.ts
function size(target) {
	if (require_isNil.isNil(target)) return 0;
	if (typeof target === "string") return require_regexMultiByte.regexMultiByte.test(target) ? require_unicodeSize.unicodeSize(target) : target.length;
	if (require_isArrayLike.isArrayLike(target)) return target.length;
	if (target instanceof Map || target instanceof Set) return target.size;
	return Object.keys(target).length;
}
exports.size = size;
