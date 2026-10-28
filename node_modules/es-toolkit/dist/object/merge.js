const require_isPlainObject = require("../predicate/isPlainObject.js");
const require_isMergeableValue = require("../_internal/isMergeableValue.js");
const require_isUnsafeProperty = require("../_internal/isUnsafeProperty.js");
// src/object/merge.ts
function merge(target, source) {
	const sourceKeys = Object.keys(source);
	for (let i = 0; i < sourceKeys.length; i++) {
		const key = sourceKeys[i];
		if (require_isUnsafeProperty.isUnsafeProperty(key)) continue;
		const sourceValue = source[key];
		const targetValue = target[key];
		if (require_isMergeableValue.isMergeableValue(sourceValue) && require_isMergeableValue.isMergeableValue(targetValue)) target[key] = merge(targetValue, sourceValue);
		else if (Array.isArray(sourceValue)) target[key] = merge([], sourceValue);
		else if (require_isPlainObject.isPlainObject(sourceValue)) target[key] = merge({}, sourceValue);
		else if (targetValue === void 0 || sourceValue !== void 0) target[key] = sourceValue;
	}
	return target;
}
exports.merge = merge;
