/**
 * Gathers elements in the same position in an internal array
 * from a grouped array of elements and returns them as a new array.
 *
 * The returned array's length matches the longest nested array.
 * Missing positions in shorter arrays are filled with `undefined`.
 *
 * @template T - The type of elements in the nested array.
 * @param array - The nested array to unzip.
 * @returns A new array of unzipped elements.
 *
 * @example
 * const zipped = [['a', true, 1],['b', false, 2]];
 * const result = unzip(zipped);
 * // result will be [['a', 'b'], [true, false], [1, 2]]
 */
export declare function unzip<T>(array: T[][] | ArrayLike<ArrayLike<T>> | null | undefined): T[][];