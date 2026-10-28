const require_baseToString = require("../_internal/baseToString.js");
const require_toNumber = require("../util/toNumber.js");
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
		value = require_baseToString.baseToString(value);
		other = require_baseToString.baseToString(other);
	} else {
		value = require_toNumber.toNumber(value);
		other = require_toNumber.toNumber(other);
	}
	return value / other;
}
exports.divide = divide;
