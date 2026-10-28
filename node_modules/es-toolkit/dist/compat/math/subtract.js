const require_baseToString = require("../_internal/baseToString.js");
const require_toNumber = require("../util/toNumber.js");
// src/compat/math/subtract.ts
/**
* Subtracts one number from another.
*
* If either of the numbers is `NaN`, the function returns `NaN`.
*
* @param value The first number. (minuend)
* @param other The second number.(subtrahend)
* @returns The difference of the two numbers, or `NaN` if any input is `NaN`.
*
* @example
* subtract(6, 3); // => 3
* subtract(6, NaN); // => NaN
* subtract(NaN, 3); // => NaN
*/
function subtract(value, other) {
	if (value === void 0 && other === void 0) return 0;
	if (value === void 0 || other === void 0) return value === void 0 ? other : value;
	if (typeof value === "string" || typeof other === "string") {
		value = require_baseToString.baseToString(value);
		other = require_baseToString.baseToString(other);
	} else {
		value = require_toNumber.toNumber(value);
		other = require_toNumber.toNumber(other);
	}
	return value - other;
}
exports.subtract = subtract;
