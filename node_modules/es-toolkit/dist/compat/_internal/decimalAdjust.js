const require_toNumber = require("../util/toNumber.js");
const require_toInteger = require("../util/toInteger.js");
// src/compat/_internal/decimalAdjust.ts
function decimalAdjust(type, number, precision = 0) {
	number = require_toNumber.toNumber(number);
	if (Object.is(number, -0)) number = "-0";
	precision = Math.min(require_toInteger.toInteger(precision), 292);
	if (precision && Number.isFinite(Number(number))) {
		const [magnitude, exponent = 0] = number.toString().split("e");
		let adjustedValue = Math[type](Number(`${magnitude}e${Number(exponent) + precision}`));
		if (Object.is(adjustedValue, -0)) adjustedValue = "-0";
		const [newMagnitude, newExponent = 0] = adjustedValue.toString().split("e");
		return Number(`${newMagnitude}e${Number(newExponent) - precision}`);
	}
	return Math[type](Number(number));
}
exports.decimalAdjust = decimalAdjust;
