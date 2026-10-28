type IteratorValue<T> = T extends Iterator<infer V> ? V : never;
/**
 * Lazily computes the [Cartesian product](https://en.wikipedia.org/wiki/Cartesian_product)
 * of the source iterators, yielding every possible tuple formed by picking one
 * element from each source, in lexicographic order — the rightmost source
 * advances fastest, like the digits of an odometer.
 *
 * Because every source except the first is traversed many times, those sources
 * are buffered into arrays when iteration starts. The first source is consumed
 * lazily, one element at a time, so it may be infinite. When iteration ends —
 * because the first source ran out, a buffered source was empty, or the
 * consumer terminated early — every source is closed via its `return` method.
 *
 * If no sources are passed, a single empty tuple is yielded, matching the
 * array `cartesianProduct`. If any source is empty, nothing is yielded.
 *
 * @template T - A tuple of the source iterator types.
 * @param sources - The iterators to take the product of.
 * @returns A lazy iterator over tuples representing the Cartesian product.
 *
 * @example
 * cartesianProduct([1, 2].values(), ['a', 'b'].values()).toArray();
 * // => [[1, 'a'], [1, 'b'], [2, 'a'], [2, 'b']]
 *
 * @example
 * // The first source may be infinite; elements are produced on demand.
 * cartesianProduct(range(0, Infinity), ['a', 'b'].values()).take(3).toArray();
 * // => [[0, 'a'], [0, 'b'], [1, 'a']]
 */
export declare function cartesianProduct<T extends Array<Iterator<unknown>>>(...sources: T): IteratorObject<{ [K in keyof T]: IteratorValue<T[K]>; }, undefined>;
export {};