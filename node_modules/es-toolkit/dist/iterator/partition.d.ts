/**
 * Consumes `source` and splits its elements into two arrays: the first holds the
 * elements for which `predicate` returns truthy, the second holds the rest.
 * Relative order is preserved within each group. This is a terminal operation:
 * it pulls every element, so it must not be used on an infinite iterator.
 *
 * @template T - The type of elements produced by the iterator.
 * @param source - The iterator to partition.
 * @param predicate - Called with `(value, index)`; truthy sends the element to the first array.
 * @returns A two-element tuple of `[matched, unmatched]` arrays.
 *
 * @example
 * partition([1, 2, 3, 4].values(), x => x % 2 === 0); // => [[2, 4], [1, 3]]
 */
export declare function partition<T>(source: Iterator<T>, predicate: (value: T, index: number) => boolean): [T[], T[]];