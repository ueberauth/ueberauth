type IteratorValue<T> = T extends Iterator<infer V> ? V : never;
/**
 * Lazily combines several iterators into a single iterator of tuples, pairing
 * the elements at matching positions. Iteration stops as soon as the **shortest**
 * source is exhausted.
 *
 * Stopping at the shortest source (rather than padding to the longest, as the
 * array `zip` does) is what makes this safe to use with infinite iterators:
 * `zip(range(0, Infinity), names.values())` ends with `names`. When iteration
 * ends — because a source ran out or the consumer terminated early — every
 * source is closed via its `return` method.
 *
 * @template T - A tuple of the source iterator types.
 * @param sources - The iterators to zip together.
 * @returns A lazy iterator over tuples of the paired elements.
 *
 * @example
 * zip([1, 2, 3].values(), ['a', 'b'].values()).toArray(); // => [[1, 'a'], [2, 'b']]
 */
export declare function zip<T extends Array<Iterator<unknown>>>(...sources: T): IteratorObject<{ [K in keyof T]: IteratorValue<T[K]>; }, undefined>;
export {};