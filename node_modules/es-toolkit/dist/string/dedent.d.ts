/**
 * Removes common leading whitespace from each line of a multi-line string.
 *
 * This function can be used as a regular function, as a tagged template literal,
 * or composed with another tag function (TC39 String.dedent proposal).
 * It calculates the common indentation across all non-empty lines and removes it,
 * preserving relative indentation differences between lines.
 * The first and last lines are removed if they are empty or contain only whitespace.
 *
 * When used as a tagged template literal or composed with a tag function, the template
 * must have the same shape `String.dedent` requires: the opening line, right after the
 * opening backtick, and the closing line, right before the closing backtick, may contain
 * only whitespace. Otherwise a `TypeError` is thrown.
 *
 * @param {string | TemplateStringsArray | Function} str - The string, template literal, or tag function to dedent.
 * @param {unknown[]} values - The values to interpolate when used as a tagged template literal.
 * @returns {string | Function} The dedented string, or a dedented tag function when composed.
 * @throws {TypeError} If a template literal has content on its opening or closing line.
 *
 * @example
 * // As a regular function
 * dedent("  hello\n  world"); // "hello\nworld"
 *
 * @example
 * // As a tagged template literal
 * dedent`
 *   hello
 *   world
 * `; // "hello\nworld"
 *
 * @example
 * // Tag composition
 * const html = dedent((strings, ...values) => strings.join(''));
 * html`
 *   <div>Hello</div>
 * `; // "<div>Hello</div>"
 */
export declare function dedent(str: string): string;
export declare function dedent(str: TemplateStringsArray, ...values: unknown[]): string;
export declare function dedent<T>(tagFn: (strings: TemplateStringsArray, ...values: unknown[]) => T): (strings: TemplateStringsArray, ...values: unknown[]) => T;