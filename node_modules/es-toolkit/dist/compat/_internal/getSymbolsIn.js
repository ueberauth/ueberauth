const require_getSymbols = require("./getSymbols.js");
// src/compat/_internal/getSymbolsIn.ts
function getSymbolsIn(object) {
	const result = [];
	while (object) {
		result.push(...require_getSymbols.getSymbols(object));
		object = Object.getPrototypeOf(object);
	}
	return result;
}
exports.getSymbolsIn = getSymbolsIn;
