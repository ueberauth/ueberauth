import { flatten } from "../../array/flatten.mjs";
import { hasOwn } from "../_internal/hasOwn.mjs";
import { toKey } from "../_internal/toKey.mjs";
import { toPath } from "./toPath.mjs";
import { get } from "../object/get.mjs";
import { last } from "../array/last.mjs";
// src/compat/util/invoke.ts
/**
* Invokes the method at `path` of `object` with the given arguments.
*
* @param object - The object to query.
* @param path - The path of the method to invoke.
* @param args - The arguments to invoke the method with.
* @returns Returns the result of the invoked method.
*
* @example
* const object = {
*   a: {
*     b: function (x, y) {
*       return x + y;
*     }
*   }
* };
*
* invoke(object, 'a.b', [1, 2]); // => 3
* invoke(object, ['a', 'b'], [1, 2]); // => 3
*/
function invoke(object, path, ...args) {
	args = flatten(args, 1);
	if (object == null) return;
	switch (typeof path) {
		case "string":
			if (typeof object === "object" && hasOwn(object, path)) return invokeImpl(object, [path], args);
			return invokeImpl(object, toPath(path), args);
		case "number":
		case "symbol": return invokeImpl(object, [path], args);
		default: if (Array.isArray(path)) return invokeImpl(object, path, args);
		else return invokeImpl(object, [path], args);
	}
}
function invokeImpl(object, path, args) {
	const parent = get(object, path.slice(0, -1), object);
	if (parent == null) return;
	let lastKey = last(path);
	const lastValue = lastKey === null || lastKey === void 0 ? void 0 : lastKey.valueOf();
	if (typeof lastValue === "number") lastKey = toKey(lastValue);
	else lastKey = String(lastKey);
	const func = get(parent, lastKey);
	return func === null || func === void 0 ? void 0 : func.apply(parent, args);
}
export { invoke };
