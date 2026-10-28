/**
 * Calculates the value at a given percentile in an array of bigints.
 *
 * This function uses the [nearest-rank method](https://en.wikipedia.org/wiki/Percentile#The_nearest-rank_method),
 * so it always returns one of the values that is already in the array and never interpolates between them.
 *
 * @param arr - An array of bigints to calculate the percentile of.
 * @param percentile - The percentile to look up, as a number between `0` and `100`.
 * @returns The bigint at the given percentile.
 * @throws {Error} If `percentile` is not a number between `0` and `100`.
 * @throws {RangeError} If the array is empty, since there is no bigint to return.
 *
 * @example
 * const result = percentile([1n, 2n, 3n, 4n, 5n], 50);
 * // result will be 3n
 *
 * const p90 = percentile([1n, 2n, 3n, 4n, 5n], 90);
 * // p90 will be 5n
 */
export declare function percentile(arr: readonly bigint[], percentile: number): bigint;