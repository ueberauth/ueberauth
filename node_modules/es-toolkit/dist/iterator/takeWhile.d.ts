/**
 * Lazily yields elements from `source` as long as `shouldContinue` returns a
 * truthy value, stopping at (and excluding) the first element for which it
 * returns a falsy value. The remaining elements are never pulled from `source`.
 *
 * The native iterator helpers offer `take` (by count) but not a predicate-based
 * `takeWhile`, which is why this is provided.
 *
 * @template T - The type of elements produced by the iterator.
 * @param source - The iterator to take elements from.
 * @param shouldContinue - Called with `(value, index)`; iteration stops once it returns falsy.
 * @returns A lazy iterator over the leading run of matching elements.
 *
 * @example
 * takeWhile([1, 2, 3, 4, 1].values(), x => x < 3).toArray(); // => [1, 2]
 */
export declare function takeWhile<T>(source: Iterator<T>, shouldContinue: (value: T, index: number) => boolean): IteratorObject<T, undefined>;