/**
 * Inverts the keys and values of an object.
 *
 * @param object - The object to invert.
 * @returns Returns the new inverted object.
 *
 * @example
 * invert({ a: 1, b: 2, c: 3 });
 * // => { '1': 'a', '2': 'b', '3': 'c' }
 */
export declare function invert(object: object): Record<string, string>;