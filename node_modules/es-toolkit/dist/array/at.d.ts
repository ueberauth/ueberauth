/**
 * Retrieves elements from an array at the specified indices.
 *
 * This function supports negative indices, which count from the end of the array.
 *
 * @template T
 * @param arr - The array to retrieve elements from.
 * @param indices - An array of indices specifying the positions of elements to retrieve.
 * @returns A new array containing the elements at the specified indices.
 *
 * @example
 * const numbers = [10, 20, 30, 40, 50];
 * const result = at(numbers, [1, 3, 4]);
 * console.log(result); // [20, 40, 50]
 */
export declare function at<T>(arr: readonly T[], indices: readonly number[]): T[];