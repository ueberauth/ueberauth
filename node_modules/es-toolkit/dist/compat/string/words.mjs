import { toString } from "../util/toString.mjs";
import { lodashWords } from "../_internal/words.mjs";
// src/compat/string/words.ts
/**
* Splits `string` into an array of its words.
*
* @param str - The string or object that is to be split into words.
* @param [pattern] - The pattern to match words.
* @returns Returns the words of `string`.
*
* @example
* const wordsArray1 = words('fred, barney, & pebbles');
* // => ['fred', 'barney', 'pebbles']
*/
function words(str, pattern, guard) {
	const input = toString(str);
	if (guard || pattern === void 0) return lodashWords(input);
	if (typeof pattern === "number") pattern = pattern.toString();
	const matched = input.match(pattern);
	return (matched == null ? [] : Array.from(matched)).filter((x) => x !== "");
}
export { words };
