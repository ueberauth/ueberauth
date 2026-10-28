const require_trim = require("../../string/trim.js");
// src/compat/string/trim.ts
function trim(str, chars, guard) {
	if (str == null) return "";
	if (guard != null || chars == null) return str.toString().trim();
	switch (typeof chars) {
		case "object": if (Array.isArray(chars)) {
			const charsToTrim = [];
			for (let i = 0; i < chars.length; i++) charsToTrim.push(...chars[i].toString().split(""));
			return require_trim.trim(str, charsToTrim);
		} else return require_trim.trim(str, chars.toString().split(""));
		default: return require_trim.trim(str, chars.toString().split(""));
	}
}
exports.trim = trim;
