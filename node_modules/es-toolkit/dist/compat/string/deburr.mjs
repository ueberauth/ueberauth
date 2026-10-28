import { deburr as deburr$1 } from "../../string/deburr.mjs";
import { toString } from "../util/toString.mjs";
// src/compat/string/deburr.ts
/**
* Basic Latin equivalents of the Latin-1 Supplement and Latin Extended-A letters (U+00C0 to U+017F),
* indexed by `charCode - 0xc0`. The `×` (U+00D7) and `÷` (U+00F7) operators are mapped to themselves.
*/
const deburredLetters = [];
for (let code = 192; code <= 383; code++) deburredLetters.push(deburr$1(String.fromCharCode(code)));
/**
* Converts a string by replacing special characters and diacritical marks with their ASCII equivalents.
* For example, "Crème brûlée" becomes "Creme brulee".
*
* Like Lodash, only Latin-1 Supplement and Latin Extended-A letters are converted and combining
* diacritical marks are removed. Other characters, such as Hangul, Cyrillic, or Greek letters, are kept as they are.
*
* @param str - The input string to be deburred.
* @returns The deburred string with special characters replaced by their ASCII equivalents.
*
* @example
* // Basic usage:
* deburr('Æthelred') // returns 'Aethelred'
*
* @example
* // Handling diacritical marks:
* deburr('München') // returns 'Munchen'
*
* @example
* // Special characters:
* deburr('Crème brûlée') // returns 'Creme brulee'
*
* @example
* // Letters outside the Latin-1 Supplement and Latin Extended-A blocks are kept:
* deburr('한국어') // returns '한국어'
* deburr('йогурт') // returns 'йогурт'
*/
function deburr(str) {
	str = toString(str);
	let index = 0;
	while (index < str.length && str.charCodeAt(index) < 192) index++;
	if (index === str.length) return str;
	let result = str.slice(0, index);
	for (; index < str.length; index++) {
		const code = str.charCodeAt(index);
		if (code >= 192 && code <= 383) {
			result += deburredLetters[code - 192];
			continue;
		}
		if (code >= 768 && code <= 879 || code >= 8400 && code <= 8447 || code >= 65056 && code <= 65071) continue;
		result += str[index];
	}
	return result;
}
export { deburr };
