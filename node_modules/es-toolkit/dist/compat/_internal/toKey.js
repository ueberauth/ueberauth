// src/compat/_internal/toKey.ts
/**
* Converts `value` to a string key if it's not a string or symbol.
*
* @private
* @param {unknown} value The value to inspect.
* @returns {string|symbol} Returns the key.
*/
function toKey(value) {
	var _value$valueOf;
	if (typeof value === "string" || typeof value === "symbol") return value;
	if (Object.is(value === null || value === void 0 || (_value$valueOf = value.valueOf) === null || _value$valueOf === void 0 ? void 0 : _value$valueOf.call(value), -0)) return "-0";
	return String(value);
}
exports.toKey = toKey;
