// src/fp/iterator/toArray.ts
/**
* Creates a function that consumes an iterator and collects its elements into an
* array, for use as the terminal step of a {@link pipe}. It delegates to the
* native `Iterator.prototype.toArray`.
*
* This is a terminal operation: it pulls every element, so it must not be used
* on an infinite iterator.
*
* @template T - The type of elements produced by the source iterator.
* @returns A function mapping an `Iterator<T>` to a `T[]`.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { map, toArray } from 'es-toolkit/fp/iterator';
*
* pipe([1, 2, 3].values(), map(x => x * 2), toArray()); // => [2, 4, 6]
*/
function toArray() {
	return function toArrayInIterator(source) {
		return Iterator.from(source).toArray();
	};
}
export { toArray };
