/**
 * Returns an array of bigints from `0n` up to, but not including, `end`.
 *
 * @param end - The exclusive end of the range.
 * @returns An array of bigints.
 *
 * @example
 * const result = range(4n);
 * // result will be [0n, 1n, 2n, 3n]
 */
export declare function range(end: bigint): bigint[];
/**
 * Returns an array of bigints from `start` up to, but not including, `end`.
 *
 * @param start - The inclusive start of the range.
 * @param end - The exclusive end of the range.
 * @returns An array of bigints.
 *
 * @example
 * const result = range(2n, 5n);
 * // result will be [2n, 3n, 4n]
 */
export declare function range(start: bigint, end: bigint): bigint[];
/**
 * Returns an array of bigints from `start` up to, but not including, `end`, incrementing by `step`.
 *
 * A negative `step` counts down. If `step` points away from `end`, an empty array is returned.
 *
 * @param start - The inclusive start of the range.
 * @param end - The exclusive end of the range.
 * @param step - The amount to increment by. Must not be `0n`.
 * @returns An array of bigints.
 * @throws {Error} If `step` is `0n`.
 *
 * @example
 * const result = range(0n, 10n, 2n);
 * // result will be [0n, 2n, 4n, 6n, 8n]
 *
 * const countdown = range(5n, 0n, -1n);
 * // countdown will be [5n, 4n, 3n, 2n, 1n]
 */
export declare function range(start: bigint, end: bigint, step: bigint): bigint[];