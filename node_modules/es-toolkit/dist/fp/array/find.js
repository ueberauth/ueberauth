// src/fp/array/find.ts
function find(predicate) {
	return function(array) {
		return array.find(predicate);
	};
}
exports.find = find;
