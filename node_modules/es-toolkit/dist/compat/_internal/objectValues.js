// src/compat/_internal/objectValues.ts
function objectValues(object) {
	const keys = Object.keys(object);
	const result = new Array(keys.length);
	for (let i = 0; i < keys.length; i++) result[i] = object[keys[i]];
	return result;
}
exports.objectValues = objectValues;
