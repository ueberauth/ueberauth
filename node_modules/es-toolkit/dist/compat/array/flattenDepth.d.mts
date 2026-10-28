import { ListOfRecursiveArraysOrValues } from "../_internal/ListOfRecursiveArraysOrValues.mjs";
/**
 * Recursively flattens array up to depth times.
 *
 * @template T
 * @param array - The array to flatten.
 * @param [depth=1] - The maximum recursion depth.
 * @returns Returns the new flattened array.
 *
 * @example
 * const array = [1, [2, [3, [4]], 5]];
 *
 * flattenDepth(array, 1);
 * // => [1, 2, [3, [4]], 5]
 *
 * flattenDepth(array, 2);
 * // => [1, 2, 3, [4], 5]
 */
export declare function flattenDepth<T>(array: ListOfRecursiveArraysOrValues<T> | null | undefined, depth?: number): T[];