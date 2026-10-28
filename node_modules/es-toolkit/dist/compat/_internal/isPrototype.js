// src/compat/_internal/isPrototype.ts
function isPrototype(value) {
	const constructor = value === null || value === void 0 ? void 0 : value.constructor;
	return value === (typeof constructor === "function" ? constructor.prototype : Object.prototype);
}
exports.isPrototype = isPrototype;
