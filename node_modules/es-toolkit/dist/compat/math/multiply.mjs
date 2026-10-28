import { baseToString } from "../_internal/baseToString.mjs";
import { toNumber } from "../util/toNumber.mjs";
// src/compat/math/multiply.ts
/**
* Multiply two numbers.
*
* If either of the numbers is `NaN`, the function returns `NaN`.
*
* @param value The first number in a multiplication
* @param other The second number in a multiplication
* @returns The product of value and other
*
* @example
* multiply(2, 3); // => 6
* multiply(2, NaN); // => NaN
* multiply(NaN, 3); // => NaN
* multiply(NaN, NaN); // => NaN
*/
function multiply(value, other) {
	if (value === void 0 && other === void 0) return 1;
	if (value === void 0 || other === void 0) return value === void 0 ? other : value;
	if (typeof value === "string" || typeof other === "string") {
		value = baseToString(value);
		other = baseToString(other);
	} else {
		value = toNumber(value);
		other = toNumber(other);
	}
	return value * other;
}
export { multiply };
