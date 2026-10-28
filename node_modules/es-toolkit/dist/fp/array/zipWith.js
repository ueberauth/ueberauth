const require_zipWith = require("../../array/zipWith.js");
// src/fp/array/zipWith.ts
function zipWith(...rest) {
	return function(array) {
		return require_zipWith.zipWith(array, ...rest);
	};
}
exports.zipWith = zipWith;
