/**
 * Deeply freezes an object, making it and all nested objects immutable.
 *
 * Unlike `Object.freeze`, which only freezes the immediate properties of an object,
 * `deepFreeze` recursively freezes all nested objects and arrays.
 *
 * @template T - The type of the object.
 * @param {T} obj - The object to deeply freeze.
 * @returns {T} The deeply frozen object.
 *
 * @example
 * const frozen = deepFreeze({ user: { name: "Alex", age: 20 } });
 *
 * frozen.user = {}; // TypeError in strict mode
 * frozen.user.age = 22; // TypeError in strict mode
 */
export declare function deepFreeze<T>(obj: T): T;