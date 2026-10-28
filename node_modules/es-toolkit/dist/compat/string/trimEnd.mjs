// src/compat/string/trimEnd.ts
/**
* Removes trailing whitespace or specified characters from a string.
*
* @param str - The string from which trailing characters will be trimmed.
* @param chars - The character(s) to remove from the end of the string.
* @param guard - Enables use as an iteratee for methods like `map`.
* @returns Returns the trimmed string.
*
* @example
* trimEnd('  abc  ');
* // => '  abc'
*
* trimEnd('-_-abc-_-', '_-');
* // => '-_-abc'
*/
function trimEnd(str, chars, guard) {
	if (str == null) return "";
	if (guard != null || chars == null) return trimEndImpl(str.toString());
	return trimEndImpl(str.toString(), chars.toString().split(""));
}
function trimEndImpl(str, chars) {
	let endIndex = str.length;
	if (chars === void 0) while (endIndex > 0 && /\s/.test(str[endIndex - 1])) endIndex--;
	else while (endIndex > 0 && chars.includes(str[endIndex - 1])) endIndex--;
	return str.substring(0, endIndex);
}
export { trimEnd };
