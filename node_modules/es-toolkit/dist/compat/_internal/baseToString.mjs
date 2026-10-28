import { isSymbol } from "../predicate/isSymbol.mjs";
// src/compat/_internal/baseToString.ts
/**
* Converts `value` to a string like Lodash's `baseToString`.
*
* Unlike `toString`, `null` and `undefined` are not special-cased, so `null` becomes `'null'`.
*
* @param value - The value to convert.
* @returns The converted string.
*/
function baseToString(value) {
	if (typeof value === "string") return value;
	if (Array.isArray(value)) {
		let result = "";
		for (let i = 0; i < value.length; i++) {
			if (i > 0) result += ",";
			result += baseToString(value[i]);
		}
		return result;
	}
	if (isSymbol(value)) return value.toString();
	const result = value + "";
	if (result === "0" && Object.is(Number(value), -0)) return "-0";
	return result;
}
export { baseToString };
