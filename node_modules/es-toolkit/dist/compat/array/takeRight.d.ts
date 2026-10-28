/**
 * Creates a slice of array with n elements taken from the end.
 *
 * @template T
 * @param array - The array to query.
 * @param [n=1] - The number of elements to take.
 * @returns Returns the slice of array.
 *
 * @example
 * takeRight([1, 2, 3]);
 * // => [3]
 *
 * @example
 * takeRight([1, 2, 3], 2);
 * // => [2, 3]
 *
 * @example
 * takeRight([1, 2, 3], 5);
 * // => [1, 2, 3]
 *
 * @example
 * takeRight([1, 2, 3], 0);
 * // => []
 */
export declare function takeRight<T>(array: ArrayLike<T> | null | undefined, n?: number): T[];