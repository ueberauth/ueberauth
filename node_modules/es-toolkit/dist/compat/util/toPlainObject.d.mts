/**
 * Converts value to a plain object flattening inherited enumerable string keyed properties of value to own properties of the plain object.
 *
 * @param value The value to convert.
 * @returns Returns the converted plain object.
 *
 * @example
 * function Foo() {
 *   this.b = 2;
 * }
 * Foo.prototype.c = 3;
 * toPlainObject(new Foo()); // { b: 2, c: 3 }
 */
export declare function toPlainObject(value?: any): any;