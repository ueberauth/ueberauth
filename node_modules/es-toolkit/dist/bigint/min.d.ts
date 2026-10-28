/**
 * Finds the smallest bigint in an array.
 *
 * This function iterates through the array and returns the smallest element. Unlike `Math.min`,
 * which cannot accept bigints, it compares values directly so arbitrarily large integers stay exact.
 *
 * @param nums - An array of bigints to search.
 * @returns The smallest bigint in the array.
 * @throws {RangeError} If the array is empty, since there is no bigint that represents "no minimum".
 *
 * @example
 * const result = min([1n, 5n, 3n]);
 * // result will be 1n
 */
export declare function min(nums: readonly bigint[]): bigint;