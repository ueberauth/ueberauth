import { isFunction } from "../../predicate/isFunction.mjs";
import { isNil } from "../../predicate/isNil.mjs";
import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { objectValues } from "../_internal/objectValues.mjs";
import { toPath } from "../util/toPath.mjs";
import { get } from "../object/get.mjs";
// src/compat/array/invokeMap.ts
/**
* Invokes the method at path of each element in collection.
*
* @template T, R
* @param collection - The collection to iterate over.
* @param path - The path of the method to invoke or the method to invoke.
* @param args - The arguments to invoke each method with.
* @returns Returns the array of results.
*
* @example
* invokeMap([[5, 1, 7], [3, 2, 1]], 'sort');
* // => [[1, 5, 7], [1, 2, 3]]
*/
function invokeMap(collection, path, ...args) {
	if (isNil(collection)) return [];
	const values = isArrayLike(collection) ? Array.from(collection) : objectValues(collection);
	const result = [];
	for (let i = 0; i < values.length; i++) {
		const value = values[i];
		if (isFunction(path)) {
			result.push(path.apply(value, args));
			continue;
		}
		const method = get(value, path);
		let thisContext = value;
		const keys = Array.isArray(path) ? path : toPath(path);
		if (keys.length > 1) thisContext = get(value, keys.slice(0, -1));
		result.push(method == null ? void 0 : method.apply(thisContext, args));
	}
	return result;
}
export { invokeMap };
