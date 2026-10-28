import { partition as partition$1 } from "../../array/partition.mjs";
// src/fp/array/partition.ts
function partition(predicate) {
	return function(array) {
		return partition$1(array, predicate);
	};
}
export { partition };
