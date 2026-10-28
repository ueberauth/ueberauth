// src/fp/flowAsync.ts
/**
* Performs left-to-right async function composition, returning a **reusable
* async function** instead of running immediately. The first function may take
* any number of arguments; every later function is unary and receives the
* awaited result of the previous one.
*
* `flowAsync` is the promise-aware sibling of {@link flow}: where `flow` passes
* each raw return value straight to the next function (so a returned `Promise`
* arrives unresolved), `flowAsync` awaits every step, letting synchronous and
* asynchronous functions mix freely in one chain. The composed function always
* returns a `Promise`.
*
* @param functions - The functions to compose. The first may be variadic; the
*   rest are unary, each receiving the awaited output of the previous function.
* @returns An async function that, when called, applies every function
*   left-to-right, awaiting each result.
*
* @example
* import { flowAsync } from 'es-toolkit/fp';
*
* const fetchUser = async (id: number) => ({ id, name: 'Alice' });
* const getName = (user: { name: string }) => user.name;
*
* const getUserName = flowAsync(fetchUser, getName);
* await getUserName(1); // => 'Alice'
*/
function flowAsync(...functions) {
	return async function(...args) {
		if (functions.length === 0) return args[0];
		let result = await functions[0].apply(this, args);
		for (let i = 1; i < functions.length; i++) result = await functions[i].call(this, result);
		return result;
	};
}
export { flowAsync };
