const require_takeWhile = require("../../iterator/takeWhile.js");
// src/fp/iterator/takeWhile.ts
/**
* Creates a function that lazily yields elements of an iterator while
* `shouldContinue` returns truthy, stopping at the first failure, for use with
* {@link pipe}.
*
* @template T - The type of elements produced by the source iterator.
* @param shouldContinue - Called with `(value, index)`; iteration stops once it returns falsy.
* @returns A function mapping an `Iterator<T>` to a lazy `IteratorObject<T>`.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { takeWhile, toArray } from 'es-toolkit/fp/iterator';
*
* pipe([1, 2, 3, 1].values(), takeWhile(x => x < 3), toArray()); // => [1, 2]
*/
function takeWhile(shouldContinue) {
	return function takeWhileInIterator(source) {
		return require_takeWhile.takeWhile(source, shouldContinue);
	};
}
exports.takeWhile = takeWhile;
