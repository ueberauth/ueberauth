const require_toString = require("../util/toString.js");
// src/compat/string/split.ts
function split(string, separator, limit) {
	return require_toString.toString(string).split(separator, limit);
}
exports.split = split;
