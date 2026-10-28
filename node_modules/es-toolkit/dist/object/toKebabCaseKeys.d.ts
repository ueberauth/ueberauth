import { ToKebabCaseKeys } from "../types/ToKebabCaseKeys.js";
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
export declare function toKebabCaseKeys<T>(obj: T): ToKebabCaseKeys<T>;