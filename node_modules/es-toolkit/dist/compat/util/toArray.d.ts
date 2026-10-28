/**
 * Converts a record or null/undefined to an array of its values.
 *
 * @template T
 * @param value - The record or null/undefined to convert.
 * @returns Returns an array of the record's values or an empty array if null/undefined.
 *
 * @example
 * toArray({ 'a': 1, 'b': 2 }) // => [1, 2]
 * toArray(null) // => []
 */
export declare function toArray<T>(value: Record<string, T> | Record<number, T> | null | undefined): T[];
/**
 * Converts a value to an array of its values.
 *
 * @template T
 * @param value - The value to convert.
 * @returns Returns an array of the value's values.
 *
 * @example
 * toArray({ x: 10, y: 20 }) // => [10, 20]
 * toArray('abc') // => ['a', 'b', 'c']
 */
export declare function toArray<T>(value: T): Array<T[keyof T]>;
/**
 * Converts an undefined value to an empty array.
 *
 * @returns Returns an empty array.
 *
 * @example
 * toArray() // => []
 */
export declare function toArray(): any[];