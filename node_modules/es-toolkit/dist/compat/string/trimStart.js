// src/compat/string/trimStart.ts
/**
* Removes leading whitespace or specified characters from a string.
*
* @param str - The string from which leading characters will be trimmed.
* @param chars - The character(s) to remove from the start of the string.
* @param guard - Enables use as an iteratee for methods like `map`.
* @returns Returns the trimmed string.
*
* @example
* trimStart('  abc  ');
* // => 'abc  '
*
* trimStart('-_-abc-_-', '_-');
* // => 'abc-_-'
*/
function trimStart(str, chars, guard) {
	if (str == null) return "";
	if (guard != null || chars == null) return trimStartImpl(str.toString());
	return trimStartImpl(str.toString(), chars.toString().split(""));
}
function trimStartImpl(str, chars) {
	let startIndex = 0;
	if (chars === void 0) while (startIndex < str.length && /\s/.test(str[startIndex])) startIndex++;
	else while (startIndex < str.length && chars.includes(str[startIndex])) startIndex++;
	return str.substring(startIndex);
}
exports.trimStart = trimStart;
