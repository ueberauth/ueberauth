import { ListIterateeCustom } from "../_internal/ListIterateeCustom.js";
/**
 * Finds the index of the first item in an array that has a specific property, where the property name is provided as a PropertyKey.
 *
 * @template T
 * @param arr - The array to search through.
 * @param doesMatch - The criteria to match against the items in the array. This can be a function, a partial object, a key-value pair, or a property name.
 * @param [fromIndex=0] - The index to start the search from, defaults to 0.
 * @returns The index of the first item that has the specified property, or `-1` if no match is found.
 *
 * @example
 * // Using a property name
 * const items = [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }];
 * const result = findIndex(items, 'name');
 * console.log(result); // 0
 */
export declare function findIndex<T>(arr: ArrayLike<T> | null | undefined, doesMatch?: ListIterateeCustom<T, boolean>, fromIndex?: number): number;