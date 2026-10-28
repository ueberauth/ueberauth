/**
 * Converts `value` to a finite number.
 *
 * @param value - The value to convert.
 * @returns Returns the number.
 *
 * @example
 * toFinite(3.2); // => 3.2
 * toFinite(Number.MIN_VALUE); // => 5e-324
 * toFinite(Infinity); // => 1.7976931348623157e+308
 * toFinite('3.2'); // => 3.2
 * toFinite(Symbol.iterator); // => 0
 * toFinite(NaN); // => 0
 */
export declare function toFinite(value: any): number;