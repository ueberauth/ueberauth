/**
 * Removes elements from an array at specified indices and returns the removed elements.
 *
 * This function supports negative indices, which count from the end of the array.
 *
 * @template T
 * @param arr - The array from which elements will be removed.
 * @param indicesToRemove - An array of indices specifying the positions of elements to remove.
 * @returns An array containing the elements that were removed from the original array.
 *
 * @example
 * const numbers = [10, 20, 30, 40, 50];
 * const removed = pullAt(numbers, [1, 3, 4]);
 * console.log(removed); // [20, 40, 50]
 * console.log(numbers); // [10, 30]
 */
export declare function pullAt<T>(arr: T[], indicesToRemove: readonly number[]): T[];