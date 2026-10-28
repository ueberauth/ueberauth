interface FlattenObjectOptions {
  /**
   * The delimiter to use between nested keys.
   * @default '.'
   */
  delimiter?: string;
  /**
   * If true, arrays are kept as values instead of being flattened.
   * @default false
   */
  preserveArrays?: boolean;
}
/**
 * Flattens a nested object into a single level object with delimiter-separated keys.
 *
 * @param object - The object to flatten.
 * @param [options.delimiter='.'] - The delimiter to use between nested keys.
 * @param [options.preserveArrays=false] - If true, arrays are kept as values instead of being flattened.
 * @returns The flattened object.
 *
 * @example
 * const nestedObject = {
 *   a: {
 *     b: {
 *       c: 1
 *     }
 *   },
 *   d: [2, 3]
 * };
 *
 * const flattened = flattenObject(nestedObject);
 * console.log(flattened);
 * // Output:
 * // {
 * //   'a.b.c': 1,
 * //   'd.0': 2,
 * //   'd.1': 3
 * // }
 *
 * const preserved = flattenObject(nestedObject, { preserveArrays: true });
 * console.log(preserved);
 * // Output:
 * // {
 * //   'a.b.c': 1,
 * //   'd': [2, 3]
 * // }
 */
export declare function flattenObject(object: object, { delimiter, preserveArrays }?: FlattenObjectOptions): Record<string, any>;
export {};