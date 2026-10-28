const require_eq = require("../util/eq.js");
const require_hasOwn = require("./hasOwn.js");
// src/compat/_internal/assignValue.ts
const assignValue = (object, key, value) => {
	const objValue = object[key];
	if (!(require_hasOwn.hasOwn(object, key) && require_eq.eq(objValue, value)) || value === void 0 && !(key in object)) object[key] = value;
};
exports.assignValue = assignValue;
