import { toString } from "../util/toString.mjs";
// src/compat/string/split.ts
function split(string, separator, limit) {
	return toString(string).split(separator, limit);
}
export { split };
