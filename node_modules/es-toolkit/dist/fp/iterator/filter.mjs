// src/fp/iterator/filter.ts
function filter(predicate) {
	return function filterInIterator(source) {
		return Iterator.from(source).filter(predicate);
	};
}
export { filter };
