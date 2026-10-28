const require_isArray = require("../compat/predicate/isArray.js");
const require_isPlainObject = require("../compat/predicate/isPlainObject.js");
const require_constantCase = require("../string/constantCase.js");
// src/object/toConstantCaseKeys.ts
/**
* Creates a new object composed of the properties with keys converted to CONSTANT_CASE.
*
* This function takes an object and returns a new object that includes the same properties,
* but with all keys converted to CONSTANT_CASE format.
*
* @template T - The type of object.
* @param obj - The object to convert keys from.
* @returns A new object with all keys converted to CONSTANT_CASE.
*
* @example
* // Example with objects
* const obj = { userId: 1, firstName: 'John' };
* const result = toConstantCaseKeys(obj);
* // result will be { USER_ID: 1, FIRST_NAME: 'John' }
*
* // Example with arrays of objects
* const arr = [
*   { userId: 1, firstName: 'John' },
*   { userId: 2, firstName: 'Jane' }
* ];
* const arrResult = toConstantCaseKeys(arr);
* // arrResult will be [{ USER_ID: 1, FIRST_NAME: 'John' }, { USER_ID: 2, FIRST_NAME: 'Jane' }]
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
* const nestedResult = toConstantCaseKeys(nested);
* // nestedResult will be:
* // {
* //   USER_DATA: {
* //     USER_ID: 1,
* //     USER_ADDRESS: {
* //       STREET_NAME: 'Main St',
* //       ZIP_CODE: '12345'
* //     }
* //   }
* // }
*/
function toConstantCaseKeys(obj) {
	if (require_isArray.isArray(obj)) return obj.map((item) => toConstantCaseKeys(item));
	if (require_isPlainObject.isPlainObject(obj)) {
		const result = {};
		const keys = Object.keys(obj);
		for (let i = 0; i < keys.length; i++) {
			const key = keys[i];
			const constantKey = require_constantCase.constantCase(key);
			result[constantKey] = toConstantCaseKeys(obj[key]);
		}
		return result;
	}
	return obj;
}
exports.toConstantCaseKeys = toConstantCaseKeys;
