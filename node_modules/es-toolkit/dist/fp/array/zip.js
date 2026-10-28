const require_zip = require("../../array/zip.js");
// src/fp/array/zip.ts
function zip(...arrs) {
	return function(array) {
		return require_zip.zip(array, ...arrs);
	};
}
exports.zip = zip;
