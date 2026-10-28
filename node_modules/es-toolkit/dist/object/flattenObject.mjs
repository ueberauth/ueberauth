import { isPlainObject } from "../predicate/isPlainObject.mjs";
// src/object/flattenObject.ts
/**
* Flattens a nested object into a single level object with delimiter-separated keys.
*
* @param object - The object to flatten.
* @param [options.delimiter='.'] - The delimiter to use between nested keys.
* @param [options.preserveArrays=false] - If true, arrays are kept as values instead of being flattened.
* @returns The flattened object.
*
* @example
* const nestedObject = {
*   a: {
*     b: {
*       c: 1
*     }
*   },
*   d: [2, 3]
* };
*
* const flattened = flattenObject(nestedObject);
* console.log(flattened);
* // Output:
* // {
* //   'a.b.c': 1,
* //   'd.0': 2,
* //   'd.1': 3
* // }
*
* const preserved = flattenObject(nestedObject, { preserveArrays: true });
* console.log(preserved);
* // Output:
* // {
* //   'a.b.c': 1,
* //   'd': [2, 3]
* // }
*/
function flattenObject(object, { delimiter = ".", preserveArrays = false } = {}) {
	return flattenObjectImpl(object, "", delimiter, preserveArrays);
}
function flattenObjectImpl(object, prefix, delimiter, preserveArrays) {
	const result = {};
	const keys = Object.keys(object);
	for (let i = 0; i < keys.length; i++) {
		const key = keys[i];
		const value = object[key];
		const prefixedKey = prefix ? `${prefix}${delimiter}${key}` : key;
		if (isPlainObject(value) && Object.keys(value).length > 0) {
			Object.assign(result, flattenObjectImpl(value, prefixedKey, delimiter, preserveArrays));
			continue;
		}
		if (Array.isArray(value) && !preserveArrays && value.length > 0) {
			Object.assign(result, flattenObjectImpl(value, prefixedKey, delimiter, preserveArrays));
			continue;
		}
		result[prefixedKey] = value;
	}
	return result;
}
export { flattenObject };
