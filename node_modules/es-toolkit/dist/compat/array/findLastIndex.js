const require_identity = require("../../function/identity.js");
const require_toArray = require("../_internal/toArray.js");
const require_property = require("../object/property.js");
const require_matches = require("../predicate/matches.js");
const require_matchesProperty = require("../predicate/matchesProperty.js");
const require_toInteger = require("../util/toInteger.js");
// src/compat/array/findLastIndex.ts
/**
* Finds the index of the last element in the array that satisfies the predicate.
*
* @template T
* @param arr - The array to search through.
* @param doesMatch - The predicate function, partial object, property-value pair, or property name.
* @param [fromIndex=arr.length - 1] - The index to start the search from, defaults to the last index of the array.
* @returns The index of the last matching element, or -1 if not found.
*
* @example
* const items = [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }];
* findLastIndex(items, 'name');
* // => 1
*/
function findLastIndex(arr, doesMatch = require_identity.identity, fromIndex = arr ? arr.length - 1 : 0) {
	if (!arr) return -1;
	const index = require_toInteger.toInteger(fromIndex);
	if (fromIndex < 0) fromIndex = Math.max(arr.length + index, 0);
	else fromIndex = Math.min(index, arr.length - 1);
	const subArray = require_toArray.toArray(arr).slice(0, fromIndex + 1);
	let predicate;
	switch (typeof doesMatch) {
		case "function":
			predicate = doesMatch;
			break;
		case "object":
			if (Array.isArray(doesMatch) && doesMatch.length === 2) {
				const key = doesMatch[0];
				const value = doesMatch[1];
				predicate = require_matchesProperty.matchesProperty(key, value);
			} else predicate = require_matches.matches(doesMatch);
			break;
		case "number":
		case "symbol":
		case "string": predicate = require_property.property(doesMatch);
	}
	for (let i = subArray.length - 1; i >= 0; i--) if (predicate(subArray[i], i, subArray)) return i;
	return -1;
}
exports.findLastIndex = findLastIndex;
