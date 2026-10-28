/**
 * Checks if `value` is likely a DOM element.
 *
 * @param value The value to check.
 * @returns Returns `true` if `value` is a DOM element, else `false`.
 *
 * @example
 * console.log(isElement(document.body)); // true
 * console.log(isElement('<body>')); // false
 */
export declare function isElement(value?: any): boolean;