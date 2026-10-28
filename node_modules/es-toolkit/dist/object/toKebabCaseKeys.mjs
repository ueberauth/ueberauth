import { isArray } from "../compat/predicate/isArray.mjs";
import { isPlainObject } from "../compat/predicate/isPlainObject.mjs";
import { kebabCase } from "../string/kebabCase.mjs";
// src/object/toKebabCaseKeys.ts
/**
* Creates a new object composed of the properties with keys converted to kebab-case.
*
* This function takes an object and returns a new object that includes the same properties,
* but with all keys converted to kebab-case format.
*
* @template T - The type of object.
* @param obj - The object to convert keys from.
* @returns A new object with all keys converted to kebab-case.
*
* @example
* // Example with objects
* const obj = { userId: 1, firstName: 'John' };
* const result = toKebabCaseKeys(obj);
* // result will be { 'user-id': 1, 'first-name': 'John' }
*
* // Example with arrays of objects
* const arr = [
*   { userId: 1, firstName: 'John' },
*   { userId: 2, firstName: 'Jane' }
* ];
* const arrResult = toKebabCaseKeys(arr);
* // arrResult will be [{ 'user-id': 1, 'first-name': 'John' }, { 'user-id': 2, 'first-name': 'Jane' }]
*
* // Example with nested objects
* const nested = {
*   userData: {
*     userId: 1,
*     userAddress: {
*       streetName: 'Main St',
*       zipCode: '12345'
*     }
*   }
* };
* const nestedResult = toKebabCaseKeys(nested);
* // nestedResult will be:
* // {
* //   'user-data': {
* //     'user-id': 1,
* //     'user-address': {
* //       'street-name': 'Main St',
* //       'zip-code': '12345'
* //     }
* //   }
* // }
*/
function toKebabCaseKeys(obj) {
	if (isArray(obj)) return obj.map((item) => toKebabCaseKeys(item));
	if (isPlainObject(obj)) {
		const result = {};
		const keys = Object.keys(obj);
		for (let i = 0; i < keys.length; i++) {
			const key = keys[i];
			const kebabKey = kebabCase(key);
			result[kebabKey] = toKebabCaseKeys(obj[key]);
		}
		return result;
	}
	return obj;
}
export { toKebabCaseKeys };
