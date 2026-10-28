// src/fp/iterator/flatMap.ts
/**
* Creates a function that lazily maps each element of an iterator to an iterable
* (or iterator) and flattens the results one level, for use with {@link pipe}.
* It delegates to the native `Iterator.prototype.flatMap`.
*
* @template T - The type of elements produced by the source iterator.
* @template U - The type of elements produced by the result.
* @param callback - Called with `(value, index)`; returns the iterable to flatten in.
* @returns A function mapping an `Iterator<T>` to a lazy `IteratorObject<U>`.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { flatMap } from 'es-toolkit/fp/iterator';
*
* pipe([1, 2].values(), flatMap(x => [x, x * 10])).toArray(); // => [1, 10, 2, 20]
*/
function flatMap(callback) {
	return function flatMapInIterator(source) {
		return Iterator.from(source).flatMap(callback);
	};
}
export { flatMap };
