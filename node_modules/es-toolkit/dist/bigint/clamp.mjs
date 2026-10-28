// src/bigint/clamp.ts
/**
* Clamps a bigint within the inclusive lower and upper bounds.
*
* @param value - The bigint to clamp.
* @param bound1 - The upper bound when called with two arguments, otherwise the lower bound.
* @param bound2 - The upper bound when called with three arguments.
* @returns The clamped bigint.
*/
function clamp(value, bound1, bound2) {
	if (bound2 == null) return value < bound1 ? value : bound1;
	const lowerClamped = value > bound1 ? value : bound1;
	return lowerClamped < bound2 ? lowerClamped : bound2;
}
export { clamp };
