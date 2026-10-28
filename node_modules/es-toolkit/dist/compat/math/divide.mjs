import { baseToString } from "../_internal/baseToString.mjs";
import { toNumber } from "../util/toNumber.mjs";
// src/compat/math/divide.ts
/**
* Divide two numbers.
*
* If either of the numbers is `NaN`, the function returns `NaN`.
*
* @param value The first number in a division.
* @param other The second number in a division.
* @returns The quotient of value and other.
*
* @example
* divide(6, 3); // => 2
* divide(2, NaN); // => NaN
* divide(NaN, 3); // => NaN
* divide(NaN, NaN); // => NaN
*/
function divide(value, other) {
	if (value === void 0 && other === void 0) return 1;
	if (value === void 0 || other === void 0) return value === void 0 ? other : value;
	if (typeof value === "string" || typeof other === "string") {
		value = baseToString(value);
		other = baseToString(other);
	} else {
		value = toNumber(value);
		other = toNumber(other);
	}
	return value / other;
}
export { divide };
