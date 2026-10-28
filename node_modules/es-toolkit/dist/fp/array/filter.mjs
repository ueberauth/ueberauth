import { combineEagerAndLazyFunctions, createLazyFunction } from "../_internal/lazy.mjs";
// src/fp/array/filter.ts
function filter(predicate) {
	function filterEager(array) {
		return array.filter(predicate);
	}
	const filterLazy = createLazyFunction((value, index, emit) => {
		if (predicate(value, index)) emit(value);
	});
	return combineEagerAndLazyFunctions(filterEager, filterLazy);
}
export { filter };
