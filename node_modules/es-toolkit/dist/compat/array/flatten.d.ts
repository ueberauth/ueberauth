/**
 * Flattens array up to depth times.
 *
 * @template T
 * @param array - The array to flatten.
 * @returns Returns the new flattened array.
 *
 * @example
 * flatten([1, [2, [3, [4]], 5]]);
 * // => [1, 2, [3, [4]], 5]
 */
export declare function flatten<T>(array: ArrayLike<T | readonly T[]> | null | undefined): T[];