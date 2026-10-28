import { lowerFirst as lowerFirst$1 } from "../../string/lowerFirst.mjs";
import { toString } from "../util/toString.mjs";
// src/compat/string/lowerFirst.ts
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
	return lowerFirst$1(toString(str));
}
export { lowerFirst };
