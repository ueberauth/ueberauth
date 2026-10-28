const require_iterator = require("./_internal/iterator.js");
// src/iterator/chunk.ts
/**
* Lazily groups the elements of `source` into arrays of length `size`. The final
* chunk holds the remaining elements when the source length is not an exact
* multiple of `size`, so it may be shorter.
*
* Each chunk is produced only when requested, so this works with infinite
* iterators when bounded by a short-circuiting helper.
*
* @template T - The type of elements produced by the iterator.
* @param source - The iterator to split into chunks.
* @param size - The length of each chunk; must be an integer greater than zero.
* @returns A lazy iterator over arrays of up to `size` elements.
* @throws {Error} Throws an error if `size` is not an integer greater than zero.
*
* @example
* chunk([1, 2, 3, 4, 5].values(), 2).toArray(); // => [[1, 2], [3, 4], [5]]
*/
function chunk(source, size) {
	if (!Number.isInteger(size) || size <= 0) throw new Error("Size must be an integer greater than zero.");
	return require_iterator.iterator(function() {
		const buffer = [];
		while (buffer.length < size) {
			const result = source.next();
			if (result.done) break;
			buffer.push(result.value);
		}
		if (buffer.length === 0) return {
			value: void 0,
			done: true
		};
		return {
			value: buffer,
			done: false
		};
	}, () => void source.return?.());
}
exports.chunk = chunk;
