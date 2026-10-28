const require_unzip = require("../../array/unzip.js");
// src/fp/array/unzip.ts
/**
* Creates a function that unzips grouped tuples into arrays by position.
*
* The returned function is the data-last form of the main {@link unzip} utility.
* Use it with {@link pipe}.
*
* When the returned function is invoked, the result's length matches the longest nested array.
* Missing positions in shorter arrays are filled with `undefined`.
*
* @template T - The tuple type inside the zipped array.
* @returns A function that maps zipped tuples to arrays grouped by tuple position.
*
* @example
* import { pipe, unzip } from 'es-toolkit/fp';
*
* pipe([[1, 'a'], [2, 'b']] as Array<[number, string]>, unzip());
* // => [[1, 2], ['a', 'b']]
*/
function unzip() {
	return function(zipped) {
		return require_unzip.unzip(zipped);
	};
}
exports.unzip = unzip;
