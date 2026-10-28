const require_identity = require("../../function/identity.js");
const require_toArray = require("../_internal/toArray.js");
const require_isArrayLike = require("../predicate/isArrayLike.js");
const require_objectValues = require("../_internal/objectValues.js");
const require_hasOwn = require("../_internal/hasOwn.js");
const require_iteratee = require("../util/iteratee.js");
// src/compat/array/groupBy.ts
/**
* Groups the elements of an array or object based on a provided key-generating function.
*
* This function takes an array or object and a function that generates a key from each element or value.
* It returns an object where the keys are the generated keys and the values are arrays of elements that
* share the same key.
*
* @template T - The type of elements in the array or values in the object.
* @template K - The type of keys.
* @param source - The collection to group.
* @param [_getKeyFromItem=identity] - The iteratee to transform keys.
*   - If a function is provided, it's invoked for each element in the collection.
*   - If a property name (string) is provided, that property of each element is used as the key.
*   - If a property-value pair (array) is provided, elements with matching property values are used.
*   - If a partial object is provided, elements with matching properties are used.
* @returns An object where each key is associated with an array of elements that
* share that key.
*
* @example
* // Using an array
* const array = [6.1, 4.2, 6.3];
* const result = groupBy(array, Math.floor);
* // => { 4: [4.2], 6: [6.1, 6.3] }
*
* @example
* // Using a property name
* const array = ['one', 'two', 'three'];
* const result = groupBy(array, 'length');
* // => { 3: ['one', 'two'], 5: ['three'] }
*/
function groupBy(source, _getKeyFromItem = require_identity.identity) {
	if (source == null) return {};
	const items = require_isArrayLike.isArrayLike(source) ? require_toArray.toArray(source) : require_objectValues.objectValues(source);
	const getKeyFromItem = require_iteratee.iteratee(_getKeyFromItem);
	const result = {};
	for (let i = 0; i < items.length; i++) {
		const item = items[i];
		const key = getKeyFromItem(item);
		if (!require_hasOwn.hasOwn(result, key)) result[key] = [];
		result[key].push(item);
	}
	return result;
}
exports.groupBy = groupBy;
