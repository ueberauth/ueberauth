// src/string/lowerFirst.ts
/**
* Converts the first character of string to lower case.
*
* @param str - The string that is to be changed
* @returns The converted string.
*
* @example
* const convertedStr1 = lowerFirst('fred') // returns 'fred'
* const convertedStr2 = lowerFirst('Fred') // returns 'fred'
* const convertedStr3 = lowerFirst('FRED') // returns 'fRED'
*/
function lowerFirst(str) {
	return str.substring(0, 1).toLowerCase() + str.substring(1);
}
export { lowerFirst };
