// src/fp/iterator/every.ts
/**
* Creates a function that consumes an iterator until `predicate` returns falsy
* and reports whether every element matched, for use as the terminal step of a
* {@link pipe}. It delegates to the native `Iterator.prototype.every` and stops
* pulling at the first non-match.
*
* @template T - The type of elements produced by the source iterator.
* @param predicate - Called with `(value, index)`; falsy short-circuits to `false`.
* @returns A function mapping an `Iterator<T>` to a boolean.
*
* @example
* import { pipe } from 'es-toolkit/fp';
* import { every } from 'es-toolkit/fp/iterator';
*
* pipe([2, 4, 6].values(), every(x => x % 2 === 0)); // => true
*/
function every(predicate) {
	return function everyInIterator(source) {
		return Iterator.from(source).every(predicate);
	};
}
export { every };
