// src/compat/_internal/words.ts
/**
* Splits strings into words for `words` and the case functions in `es-toolkit/compat`.
*
* The patterns are lodash's own. They only use ES5 regular expression features, so they also
* work on engines without Unicode property escapes (`\p{...}`), such as Node.js 6.
*
* @link https://github.com/lodash/lodash/blob/4.17.21-es/_unicodeWords.js
* @link https://github.com/lodash/lodash/blob/4.17.21-es/_asciiWords.js
* @link https://github.com/lodash/lodash/blob/4.17.21-es/_hasUnicodeWord.js
*/
/** Used to compose unicode character classes. */
const rsAstralRange = "\\ud800-\\udfff";
const rsComboRange = "\\u0300-\\u036f\\ufe20-\\ufe2f\\u20d0-\\u20ff";
const rsDingbatRange = "\\u2700-\\u27bf";
const rsLowerRange = "a-z\\xdf-\\xf6\\xf8-\\xff";
const rsUpperRange = "A-Z\\xc0-\\xd6\\xd8-\\xde";
const rsVarRange = "\\ufe0e\\ufe0f";
const rsBreakRange = "\\xac\\xb1\\xd7\\xf7\\x00-\\x2f\\x3a-\\x40\\x5b-\\x60\\x7b-\\xbf\\u2000-\\u206f \\t\\x0b\\f\\xa0\\ufeff\\n\\r\\u2028\\u2029\\u1680\\u180e\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200a\\u202f\\u205f\\u3000";
/** Used to compose unicode capture groups. */
const rsApos = "['’]";
const rsBreak = `[${rsBreakRange}]`;
const rsCombo = `[${rsComboRange}]`;
const rsDigits = "\\d+";
const rsDingbat = `[${rsDingbatRange}]`;
const rsLower = `[${rsLowerRange}]`;
const rsMisc = `[^${rsAstralRange}${rsBreakRange}${rsDigits}${rsDingbatRange}${rsLowerRange}${rsUpperRange}]`;
const rsModifier = `(?:${rsCombo}|\\ud83c[\\udffb-\\udfff])`;
const rsNonAstral = `[^${rsAstralRange}]`;
const rsRegional = "(?:\\ud83c[\\udde6-\\uddff]){2}";
const rsSurrPair = "[\\ud800-\\udbff][\\udc00-\\udfff]";
const rsUpper = `[${rsUpperRange}]`;
const rsZWJ = "\\u200d";
/** Used to compose unicode regexes. */
const rsMiscLower = `(?:${rsLower}|${rsMisc})`;
const rsMiscUpper = `(?:${rsUpper}|${rsMisc})`;
const rsOptContrLower = `(?:${rsApos}(?:d|ll|m|re|s|t|ve))?`;
const rsOptContrUpper = `(?:${rsApos}(?:D|LL|M|RE|S|T|VE))?`;
const reOptMod = `${rsModifier}?`;
const rsOptVar = `[${rsVarRange}]?`;
const rsOptJoin = `(?:${rsZWJ}(?:${[
	rsNonAstral,
	rsRegional,
	rsSurrPair
].join("|")})${rsOptVar}${reOptMod})*`;
const rsOrdLower = "\\d*(?:1st|2nd|3rd|(?![123])\\dth)(?=\\b|[A-Z_])";
const rsOrdUpper = "\\d*(?:1ST|2ND|3RD|(?![123])\\dTH)(?=\\b|[a-z_])";
const rsSeq = rsOptVar + reOptMod + rsOptJoin;
const rsEmoji = `(?:${[
	rsDingbat,
	rsRegional,
	rsSurrPair
].join("|")})${rsSeq}`;
/** Used to detect strings that need a more robust regexp to match words. */
const reHasUnicodeWord = /[a-z][A-Z]|[A-Z]{2}[a-z]|[0-9][a-zA-Z]|[a-zA-Z][0-9]|[^a-zA-Z0-9 ]/;
/** Used to match words composed of alphanumeric characters. */
const reAsciiWord = /[^\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]+/g;
let reUnicodeWord;
/** Used to match complex or compound words. */
function getUnicodeWordPattern() {
	if (reUnicodeWord == null) reUnicodeWord = RegExp([
		`${rsUpper}?${rsLower}+${rsOptContrLower}(?=${[
			rsBreak,
			rsUpper,
			"$"
		].join("|")})`,
		`${rsMiscUpper}+${rsOptContrUpper}(?=${[
			rsBreak,
			rsUpper + rsMiscLower,
			"$"
		].join("|")})`,
		`${rsUpper}?${rsMiscLower}+${rsOptContrLower}`,
		`${rsUpper}+${rsOptContrUpper}`,
		rsOrdUpper,
		rsOrdLower,
		rsDigits,
		rsEmoji
	].join("|"), "g");
	return reUnicodeWord;
}
/**
* Splits `string` into words with lodash's own word patterns, so that `words` and the case
* functions match lodash exactly on every engine.
*
* @param string - The string to split.
* @returns The words of `string`.
*/
function lodashWords(string) {
	const pattern = reHasUnicodeWord.test(string) ? getUnicodeWordPattern() : reAsciiWord;
	const matched = string.match(pattern);
	return matched == null ? [] : Array.from(matched);
}
exports.lodashWords = lodashWords;
