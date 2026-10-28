/**
 * Checks whether a bigint is within a range.
 *
 * The lower bound is inclusive and the upper bound is exclusive, so `inRange(5n, 0n, 5n)` is `false`.
 *
 * @param value - The bigint to check.
 * @param maximum - The exclusive upper bound. The lower bound defaults to `0n`.
 * @returns `true` if the bigint is within the range, `false` otherwise.
 * @throws {Error} If the minimum is greater than or equal to the maximum.
 *
 * @example
 * const result = inRange(3n, 5n);
 * // result will be true, because 3n is within [0n, 5n)
 */
export declare function inRange(value: bigint, maximum: bigint): boolean;
/**
 * Checks whether a bigint is within a range.
 *
 * The lower bound is inclusive and the upper bound is exclusive, so `inRange(5n, 0n, 5n)` is `false`.
 *
 * @param value - The bigint to check.
 * @param minimum - The inclusive lower bound.
 * @param maximum - The exclusive upper bound.
 * @returns `true` if the bigint is within the range, `false` otherwise.
 * @throws {Error} If the minimum is greater than or equal to the maximum.
 *
 * @example
 * const result = inRange(5n, 0n, 10n);
 * // result will be true
 *
 * const result2 = inRange(10n, 0n, 10n);
 * // result2 will be false, because the upper bound is exclusive
 */
export declare function inRange(value: bigint, minimum: bigint, maximum: bigint): boolean;