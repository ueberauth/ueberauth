const require_once = require("../../function/once.js");
// src/compat/function/once.ts
function once(func) {
	return require_once.once(func);
}
exports.once = once;
