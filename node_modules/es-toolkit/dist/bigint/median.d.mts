/**
 * Calculates the median of an array of bigints.
 *
 * The median is the middle value of a sorted array. When the array has an even number of elements,
 * the two middle values are averaged. Because bigints have no fractional part, that average is
 * truncated toward zero: `median([1n, 2n])` is `1n` and `median([-3n, -2n])` is `-2n`.
 *
 * @param nums - An array of bigints to calculate the median of.
 * @returns The median of the array.
 * @throws {RangeError} If the array is empty, since there is no bigint that represents "no median".
 *
 * @example
 * const result = median([1n, 2n, 3n, 4n, 5n]);
 * // result will be 3n
 *
 * const truncated = median([1n, 2n, 3n, 4n]);
 * // truncated will be 2n, because (2n + 3n) / 2n truncates toward zero
 */
export declare function median(nums: readonly bigint[]): bigint;