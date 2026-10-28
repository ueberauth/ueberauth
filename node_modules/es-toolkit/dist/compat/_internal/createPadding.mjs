import { regexMultiByte } from "./regexMultiByte.mjs";
// src/compat/_internal/createPadding.ts
function stringSize(str) {
	return regexMultiByte.test(str) ? Array.from(str).length : str.length;
}
function createPadding(length, chars) {
	const charsLength = stringSize(chars);
	if (charsLength === 0 || length < 1) return "";
	const result = chars.repeat(Math.ceil(length / charsLength));
	return regexMultiByte.test(result) ? Array.from(result).slice(0, length).join("") : result.slice(0, length);
}
export { createPadding, stringSize };
