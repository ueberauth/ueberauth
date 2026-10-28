import { bigIntRangeLength } from "../_internal/bigIntRangeLength.mjs";
// src/bigint/rangeRight.ts
/**
* Returns an array of bigints from `start` up to, but not including, `end`, incrementing by `step`,
* in descending order.
*
* @param start - The exclusive end of the range when called with one argument, otherwise the inclusive start.
* @param end - The exclusive end of the range.
* @param step - The amount to increment by. Must not be `0n`.
* @returns An array of bigints.
* @throws {Error} If `step` is `0n`.
*/
function rangeRight(start, end, step = 1n) {
	if (end == null) {
		end = start;
		start = 0n;
	}
	if (step === 0n) throw new Error("The step value must be a non-zero bigint.");
	const length = bigIntRangeLength(start, end, step);
	const result = new Array(length);
	for (let i = 0; i < length; i++) result[i] = start + BigInt(length - i - 1) * step;
	return result;
}
export { rangeRight };
