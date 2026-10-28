/**
 * Finds the element in an array that has the smallest bigint value returned by `getValue`.
 *
 * This function maps every element to a bigint and returns the element with the smallest value.
 * If several elements tie, the first one is returned.
 *
 * @template T - The type of elements in the array.
 * @param items - An array of elements to search.
 * @param getValue - A function that maps an element to the bigint to compare by.
 * @returns The element with the smallest mapped bigint.
 * @throws {RangeError} If the array is empty, since there is no element to return.
 *
 * @example
 * const accounts = [{ balance: 10n }, { balance: 30n }, { balance: 20n }];
 * const result = minBy(accounts, account => account.balance);
 * // result will be { balance: 10n }
 */
export declare function minBy<T>(items: readonly T[], getValue: (element: T, index: number, array: readonly T[]) => bigint): T;