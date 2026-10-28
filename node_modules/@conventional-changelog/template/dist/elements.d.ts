/**
 * Renders an array into newline-separated non-empty strings.
 * @param array - Items to render.
 * @param callback - Item renderer.
 * @param separator - Separator inserted between rendered items.
 * @returns Rendered string.
 */
export declare function each<T>(array: T[] | null | undefined | false, callback: (item: T) => string | number | null | undefined | false, separator?: string): string;
/**
 * Renders a Markdown heading.
 * @param level - Markdown heading level.
 * @param text - Heading text.
 * @returns Markdown heading.
 */
export declare function heading(level: number, text: string): string;
/**
 * Renders a Markdown link.
 * @param text - Link text.
 * @param url - Link URL.
 * @returns Markdown link.
 */
export declare function link(text: string, url: string): string;
/**
 * Renders an array into a Markdown unordered list.
 * @param array - Items to render.
 * @param callback - Item renderer.
 * @returns Markdown unordered list.
 */
export declare function list<T>(array: T[] | null | undefined | false, callback: (item: T) => string | null | undefined | false): string;
/**
 * Renders bold Markdown text.
 * @param text - Text to render.
 * @returns Bold Markdown text.
 */
export declare function bold(text: string): string;
/**
 * Renders italic Markdown text.
 * @param text - Text to render.
 * @returns Italic Markdown text.
 */
export declare function italic(text: string): string;
/**
 * Renders text inside an HTML small element.
 * @param text - Text to render.
 * @returns HTML small element.
 */
export declare function small(text: string): string;
/**
 * Creates one or more newline characters.
 * @param times - Number of newline characters to render.
 * @returns Newline characters.
 */
export declare function newline(times?: number): string;
/**
 * Renders values without separators.
 * @param values - Values to render.
 * @returns Concatenated non-empty values.
 */
export declare function strings(...values: (string | number | null | undefined | false)[]): string;
/**
 * Renders values as Markdown blocks separated by blank lines.
 * @param values - Values to render.
 * @returns Rendered non-empty block segments.
 */
export declare function segments(...values: (string | number | null | undefined | false)[]): string;
/**
 * Renders values as space-separated words.
 * @param values - Values to render.
 * @returns Rendered non-empty words.
 */
export declare function words(...values: (string | number | null | undefined | false)[]): string;
/**
 * Joins URL path segments and trims extra slashes around each segment.
 * @param parts - URL path segments.
 * @returns Joined URL.
 */
export declare function url(...parts: (string | number | null | undefined)[]): string;
//# sourceMappingURL=elements.d.ts.map