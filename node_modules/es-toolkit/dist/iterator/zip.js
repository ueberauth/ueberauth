const require_iterator = require("./_internal/iterator.js");
// src/iterator/zip.ts
/**
* Lazily combines several iterators into a single iterator of tuples, pairing
* the elements at matching positions. Iteration stops as soon as the **shortest**
* source is exhausted.
*
* Stopping at the shortest source (rather than padding to the longest, as the
* array `zip` does) is what makes this safe to use with infinite iterators:
* `zip(range(0, Infinity), names.values())` ends with `names`. When iteration
* ends — because a source ran out or the consumer terminated early — every
* source is closed via its `return` method.
*
* @template T - A tuple of the source iterator types.
* @param sources - The iterators to zip together.
* @returns A lazy iterator over tuples of the paired elements.
*
* @example
* zip([1, 2, 3].values(), ['a', 'b'].values()).toArray(); // => [[1, 'a'], [2, 'b']]
*/
function zip(...sources) {
	return require_iterator.iterator(function() {
		if (sources.length === 0) return {
			value: void 0,
			done: true
		};
		const tuple = new Array(sources.length);
		for (let index = 0; index < sources.length; index++) {
			const result = sources[index].next();
			if (result.done) return {
				value: void 0,
				done: true
			};
			tuple[index] = result.value;
		}
		return {
			value: tuple,
			done: false
		};
	}, () => {
		for (const source of sources) source.return?.();
	});
}
exports.zip = zip;
