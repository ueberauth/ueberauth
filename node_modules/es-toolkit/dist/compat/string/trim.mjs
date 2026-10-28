import { trim as trim$1 } from "../../string/trim.mjs";
// src/compat/string/trim.ts
function trim(str, chars, guard) {
	if (str == null) return "";
	if (guard != null || chars == null) return str.toString().trim();
	switch (typeof chars) {
		case "object": if (Array.isArray(chars)) {
			const charsToTrim = [];
			for (let i = 0; i < chars.length; i++) charsToTrim.push(...chars[i].toString().split(""));
			return trim$1(str, charsToTrim);
		} else return trim$1(str, chars.toString().split(""));
		default: return trim$1(str, chars.toString().split(""));
	}
}
export { trim };
