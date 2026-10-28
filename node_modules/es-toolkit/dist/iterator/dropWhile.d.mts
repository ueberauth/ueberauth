/**
 * Lazily skips elements from `source` as long as `shouldDrop` returns a truthy
 * value, then yields every remaining element (including the one that first
 * failed the predicate).
 *
 * The native iterator helpers offer `drop` (by count) but not a predicate-based
 * `dropWhile`, which is why this is provided.
 *
 * @template T - The type of elements produced by the iterator.
 * @param source - The iterator to drop elements from.
 * @param shouldDrop - Called with `(value, index)`; elements are skipped while it returns truthy.
 * @returns A lazy iterator over the elements after the dropped leading run.
 *
 * @example
 * dropWhile([1, 2, 3, 1].values(), x => x < 3).toArray(); // => [3, 1]
 */
export declare function dropWhile<T>(source: Iterator<T>, shouldDrop: (value: T, index: number) => boolean): IteratorObject<T, undefined>;