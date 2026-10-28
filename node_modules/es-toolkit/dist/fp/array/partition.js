const require_partition = require("../../array/partition.js");
// src/fp/array/partition.ts
function partition(predicate) {
	return function(array) {
		return require_partition.partition(array, predicate);
	};
}
exports.partition = partition;
