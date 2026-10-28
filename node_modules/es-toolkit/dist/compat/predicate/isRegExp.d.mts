/**
 * Checks if `value` is a RegExp.
 *
 * @param value The value to check.
 * @returns Returns `true` if `value` is a RegExp, `false` otherwise.
 *
 * @example
 * const value1 = /abc/;
 * const value2 = '/abc/';
 *
 * console.log(isRegExp(value1)); // true
 * console.log(isRegExp(value2)); // false
 */
export declare function isRegExp(value?: any): value is RegExp;