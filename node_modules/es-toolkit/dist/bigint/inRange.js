// src/bigint/inRange.ts
/**
* Checks whether a bigint is within a range.
*
* @param value - The bigint to check.
* @param minimum - The exclusive upper bound when called with two arguments, otherwise the inclusive lower bound.
* @param maximum - The exclusive upper bound when called with three arguments.
* @returns `true` if the bigint is within the range, `false` otherwise.
* @throws {Error} If the minimum is greater than or equal to the maximum.
*/
function inRange(value, minimum, maximum) {
	if (maximum == null) {
		maximum = minimum;
		minimum = 0n;
	}
	if (minimum >= maximum) throw new Error("The maximum value must be greater than the minimum value.");
	return minimum <= value && value < maximum;
}
exports.inRange = inRange;
