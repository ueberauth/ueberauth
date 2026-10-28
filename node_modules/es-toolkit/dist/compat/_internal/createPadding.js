const require_regexMultiByte = require("./regexMultiByte.js");
// src/compat/_internal/createPadding.ts
function stringSize(str) {
	return require_regexMultiByte.regexMultiByte.test(str) ? Array.from(str).length : str.length;
}
function createPadding(length, chars) {
	const charsLength = stringSize(chars);
	if (charsLength === 0 || length < 1) return "";
	const result = chars.repeat(Math.ceil(length / charsLength));
	return require_regexMultiByte.regexMultiByte.test(result) ? Array.from(result).slice(0, length).join("") : result.slice(0, length);
}
exports.createPadding = createPadding;
exports.stringSize = stringSize;
