import { zip as zip$1 } from "../../iterator/zip.mjs";
// src/fp/iterator/zip.ts
/**
* Creates a function that lazily pairs the elements of the piped iterator with
* those of `other`, for use with {@link pipe}. Iteration stops as soon as either
* iterator is exhausted.
*
* @template T - The type of elements produced by the piped iterator.
* @template U - The type of elements produced by `other`.
* @param other - The iterator to pair with the piped one.
* @returns A function mapping an `Iterator<T>` to a lazy `IteratorObject<[T, U]>`.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { zip, toArray } from 'es-toolkit/fp/iterator';
*
* pipe([1, 2, 3].values(), zip(['a', 'b'].values()), toArray()); // => [[1, 'a'], [2, 'b']]
*/
function zip(other) {
	return function zipInIterator(source) {
		return zip$1(source, other);
	};
}
export { zip };
