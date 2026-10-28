import { isArray } from "../compat/predicate/isArray.mjs";
import { isPlainObject } from "../compat/predicate/isPlainObject.mjs";
import { pascalCase } from "../string/pascalCase.mjs";
// src/object/toPascalCaseKeys.ts
/**
* Creates a new object composed of the properties with keys converted to PascalCase.
*
* This function takes an object and returns a new object that includes the same properties,
* but with all keys converted to PascalCase format.
*
* @template T - The type of object.
* @param obj - The object to convert keys from.
* @returns A new object with all keys converted to PascalCase.
*
* @example
* // Example with objects
* const obj = { userId: 1, firstName: 'John' };
* const result = toPascalCaseKeys(obj);
* // result will be { UserId: 1, FirstName: 'John' }
*
* // Example with arrays of objects
* const arr = [
*   { userId: 1, firstName: 'John' },
*   { userId: 2, firstName: 'Jane' }
* ];
* const arrResult = toPascalCaseKeys(arr);
* // arrResult will be [{ UserId: 1, FirstName: 'John' }, { UserId: 2, FirstName: 'Jane' }]
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
* const nestedResult = toPascalCaseKeys(nested);
* // nestedResult will be:
* // {
* //   UserData: {
* //     UserId: 1,
* //     UserAddress: {
* //       StreetName: 'Main St',
* //       ZipCode: '12345'
* //     }
* //   }
* // }
*/
function toPascalCaseKeys(obj) {
	if (isArray(obj)) return obj.map((item) => toPascalCaseKeys(item));
	if (isPlainObject(obj)) {
		const result = {};
		const keys = Object.keys(obj);
		for (let i = 0; i < keys.length; i++) {
			const key = keys[i];
			const pascalKey = pascalCase(key);
			result[pascalKey] = toPascalCaseKeys(obj[key]);
		}
		return result;
	}
	return obj;
}
export { toPascalCaseKeys };
