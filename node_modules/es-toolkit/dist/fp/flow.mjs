import { pipe } from "./pipe.mjs";
// src/fp/flow.ts
/**
* Performs left-to-right function composition, returning a **reusable function**
* instead of running immediately. The first function may take any number of
* arguments; every later function is unary and receives the previous result.
*
* `flow` is the deferred sibling of {@link pipe}: where `pipe(value, ...fns)`
* threads a concrete value through the functions right away, `flow(...fns)`
* builds a function you can call later (and reuse) with the data. Internally it
* delegates to `pipe`, so lazy-capable functions (`map`, `filter`, `take`, …)
* are fused exactly the same way and benefit from early termination.
*
* @param functions - The functions to compose. The first may be variadic; the
*   rest are unary, each receiving the previous function's output.
* @returns A function that, when called, applies every function left-to-right.
*
* @example
* import { flow } from 'es-toolkit/fp';
*
* const addThenSquare = flow(
*   (x: number, y: number) => x + y,
*   n => n * n
* );
*
* addThenSquare(1, 2); // => 9
*
* @example
* import { flow, map, filter, take } from 'es-toolkit/fp';
*
* // A reusable lazy pipeline. Only the first two even squares are computed.
* const firstTwoEvenSquares = flow(
*   map((x: number) => x * x),
*   filter(x => x % 2 === 0),
*   take(2)
* );
*
* firstTwoEvenSquares([1, 2, 3, 4, 5, 6, 7, 8]); // => [4, 16]
*/
function flow(...functions) {
	const run = pipe;
	return function(...args) {
		if (functions.length === 0) return args[0];
		if (args.length <= 1) return run(args[0], ...functions);
		const [first, ...rest] = functions;
		return run(first.apply(this, args), ...rest);
	};
}
export { flow };
