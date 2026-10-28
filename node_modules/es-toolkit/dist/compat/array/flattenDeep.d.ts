import { ListOfRecursiveArraysOrValues } from "../_internal/ListOfRecursiveArraysOrValues.js";
/**
 * Recursively flattens array.
 *
 * @template T
 * @param array - The array to flatten.
 * @returns Returns the new flattened array.
 *
 * @example
 * flattenDeep([1, [2, [3, [4]], 5]]);
 * // => [1, 2, 3, 4, 5]
 */
export declare function flattenDeep<T>(array: ListOfRecursiveArraysOrValues<T> | null | undefined): Array<T extends string ? T : T extends ArrayLike<any> ? never : T>;