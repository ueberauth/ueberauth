const require_dropWhile = require("../../iterator/dropWhile.js");
// src/fp/iterator/dropWhile.ts
/**
* Creates a function that lazily skips elements of an iterator while `shouldDrop`
* returns truthy, then yields the rest, for use with {@link pipe}.
*
* @template T - The type of elements produced by the source iterator.
* @param shouldDrop - Called with `(value, index)`; elements are skipped while it returns truthy.
* @returns A function mapping an `Iterator<T>` to a lazy `IteratorObject<T>`.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { dropWhile, toArray } from 'es-toolkit/fp/iterator';
*
* pipe([1, 2, 3, 1].values(), dropWhile(x => x < 3), toArray()); // => [3, 1]
*/
function dropWhile(shouldDrop) {
	return function dropWhileInIterator(source) {
		return require_dropWhile.dropWhile(source, shouldDrop);
	};
}
exports.dropWhile = dropWhile;
