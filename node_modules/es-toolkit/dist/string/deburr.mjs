// src/string/deburr.ts
const deburrMap = /* @__PURE__ */ new Map([
	["Æ", "Ae"],
	["Ð", "D"],
	["Ø", "O"],
	["Þ", "Th"],
	["ß", "ss"],
	["æ", "ae"],
	["ð", "d"],
	["ø", "o"],
	["þ", "th"],
	["Đ", "D"],
	["đ", "d"],
	["Ħ", "H"],
	["ħ", "h"],
	["ı", "i"],
	["Ĳ", "IJ"],
	["ĳ", "ij"],
	["ĸ", "k"],
	["Ŀ", "L"],
	["ŀ", "l"],
	["Ł", "L"],
	["ł", "l"],
	["ŉ", "'n"],
	["Ŋ", "N"],
	["ŋ", "n"],
	["Œ", "Oe"],
	["œ", "oe"],
	["Ŧ", "T"],
	["ŧ", "t"],
	["ſ", "s"]
]);
/**
* Converts a string by replacing special characters and diacritical marks with their ASCII equivalents.
* For example, "Crème brûlée" becomes "Creme brulee".
*
* Only Latin letters are converted. Letters of other scripts, such as Hangul, Cyrillic, or Greek,
* are kept as they are, even if they carry diacritical marks.
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
* // Letters of other scripts are kept as they are:
* deburr('한국어') // returns '한국어'
* deburr('йогурт') // returns 'йогурт'
*/
function deburr(str) {
	let result = "";
	for (let index = 0; index < str.length; index++) result += deburrChar(str[index]);
	return result;
}
function deburrChar(char) {
	const code = char.charCodeAt(0);
	if (code < 128) return char;
	if (isCombiningMark(code)) return "";
	const deburred = deburrMap.get(char);
	if (deburred != null) return deburred;
	if (!isLatinLetter(code)) return char;
	const decomposed = char.normalize("NFD");
	let result = "";
	for (let index = 0; index < decomposed.length; index++) if (!isCombiningMark(decomposed.charCodeAt(index))) {
		var _deburrMap$get;
		result += (_deburrMap$get = deburrMap.get(decomposed[index])) !== null && _deburrMap$get !== void 0 ? _deburrMap$get : decomposed[index];
	}
	return result;
}
function isLatinLetter(code) {
	return code >= 192 && code <= 563 || code >= 7680 && code <= 7929 || code === 8490 || code === 8491;
}
function isCombiningMark(code) {
	return code >= 768 && code <= 879 || code >= 8400 && code <= 8447 || code >= 65056 && code <= 65071;
}
export { deburr };
