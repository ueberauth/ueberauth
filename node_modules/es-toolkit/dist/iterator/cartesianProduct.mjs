import { iterator } from "./_internal/iterator.mjs";
// src/iterator/cartesianProduct.ts
/**
* Lazily computes the [Cartesian product](https://en.wikipedia.org/wiki/Cartesian_product)
* of the source iterators, yielding every possible tuple formed by picking one
* element from each source, in lexicographic order — the rightmost source
* advances fastest, like the digits of an odometer.
*
* Because every source except the first is traversed many times, those sources
* are buffered into arrays when iteration starts. The first source is consumed
* lazily, one element at a time, so it may be infinite. When iteration ends —
* because the first source ran out, a buffered source was empty, or the
* consumer terminated early — every source is closed via its `return` method.
*
* If no sources are passed, a single empty tuple is yielded, matching the
* array `cartesianProduct`. If any source is empty, nothing is yielded.
*
* @template T - A tuple of the source iterator types.
* @param sources - The iterators to take the product of.
* @returns A lazy iterator over tuples representing the Cartesian product.
*
* @example
* cartesianProduct([1, 2].values(), ['a', 'b'].values()).toArray();
* // => [[1, 'a'], [1, 'b'], [2, 'a'], [2, 'b']]
*
* @example
* // The first source may be infinite; elements are produced on demand.
* cartesianProduct(range(0, Infinity), ['a', 'b'].values()).take(3).toArray();
* // => [[0, 'a'], [0, 'b'], [1, 'a']]
*/
function cartesianProduct(...sources) {
	const pools = [];
	const indices = [];
	let firstValue;
	let state = "initial";
	return iterator(function() {
		if (state === "done") return {
			value: void 0,
			done: true
		};
		if (state === "initial") {
			state = "active";
			if (sources.length === 0) {
				state = "done";
				return {
					value: [],
					done: false
				};
			}
			for (let index = 1; index < sources.length; index++) {
				const pool = [];
				let step = sources[index].next();
				while (!step.done) {
					pool.push(step.value);
					step = sources[index].next();
				}
				pools.push(pool);
			}
			if (pools.some((pool) => pool.length === 0)) return {
				value: void 0,
				done: true
			};
			const step = sources[0].next();
			if (step.done) return {
				value: void 0,
				done: true
			};
			firstValue = step.value;
			for (let index = 0; index < pools.length; index++) indices.push(0);
		}
		const tuple = new Array(sources.length);
		tuple[0] = firstValue;
		for (let index = 0; index < indices.length; index++) tuple[index + 1] = pools[index][indices[index]];
		let position = indices.length - 1;
		while (position >= 0) {
			indices[position]++;
			if (indices[position] < pools[position].length) break;
			indices[position] = 0;
			position--;
		}
		if (position < 0) {
			const step = sources[0].next();
			if (step.done) state = "done";
			else firstValue = step.value;
		}
		return {
			value: tuple,
			done: false
		};
	}, () => {
		for (const source of sources) source.return?.();
	});
}
export { cartesianProduct };
