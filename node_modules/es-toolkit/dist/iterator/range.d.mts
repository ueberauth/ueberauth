/**
 * Lazily yields numbers from `0` (inclusive) up to `end` (exclusive), incrementing by `1`.
 *
 * Unlike `es-toolkit`'s array `range`, this produces a lazy {@link IteratorObject}:
 * no numbers are computed until the iterator is consumed, so it composes with
 * other iterator helpers and supports early termination.
 *
 * @param end - The end number of the range (exclusive).
 * @returns A lazy iterator over the numbers in the range.
 *
 * @example
 * range(4).toArray(); // => [0, 1, 2, 3]
 */
export declare function range(end: number): IteratorObject<number, undefined>;
/**
 * Lazily yields numbers from `start` (inclusive) up to `end` (exclusive), incrementing by `1`.
 *
 * @param start - The starting number of the range (inclusive).
 * @param end - The end number of the range (exclusive).
 * @returns A lazy iterator over the numbers in the range.
 *
 * @example
 * range(1, 4).toArray(); // => [1, 2, 3]
 */
export declare function range(start: number, end: number): IteratorObject<number, undefined>;
/**
 * Lazily yields numbers from `start` (inclusive) up to `end` (exclusive), incrementing by `step`.
 *
 * @param start - The starting number of the range (inclusive).
 * @param end - The end number of the range (exclusive).
 * @param step - The step value for the range.
 * @returns A lazy iterator over the numbers in the range.
 * @throws {Error} Throws an error if the step value is not a non-zero integer.
 *
 * @example
 * range(0, 20, 5).toArray(); // => [0, 5, 10, 15]
 * range(0, -4, -1).toArray(); // => [0, -1, -2, -3]
 */
export declare function range(start: number, end: number, step: number): IteratorObject<number, undefined>;