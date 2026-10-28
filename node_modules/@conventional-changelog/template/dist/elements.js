/**
 * Converts a renderable value to a string.
 * @param value - Value to render.
 * @returns String value, or an empty string for empty values.
 */
function toString(value) {
    return typeof value === 'number' || value ? String(value) : '';
}
/**
 * Renders an array into newline-separated non-empty strings.
 * @param array - Items to render.
 * @param callback - Item renderer.
 * @param separator - Separator inserted between rendered items.
 * @returns Rendered string.
 */
export function each(array, callback, separator = newline()) {
    return array
        ? array.reduce((acc, item) => {
            const rendered = toString(callback(item)).trim();
            return `${acc}${acc && rendered ? separator : ''}${rendered}`;
        }, '')
        : '';
}
/**
 * Renders a Markdown heading.
 * @param level - Markdown heading level.
 * @param text - Heading text.
 * @returns Markdown heading.
 */
export function heading(level, text) {
    return `${'#'.repeat(level)} ${text}`;
}
/**
 * Renders a Markdown link.
 * @param text - Link text.
 * @param url - Link URL.
 * @returns Markdown link.
 */
export function link(text, url) {
    return `[${text}](${url})`;
}
/**
 * Renders an array into a Markdown unordered list.
 * @param array - Items to render.
 * @param callback - Item renderer.
 * @returns Markdown unordered list.
 */
export function list(array, callback) {
    return each(array, (item) => {
        const rendered = toString(callback(item)).trim();
        const itemText = rendered
            .split(/\r?\n/)
            .map((line, index) => (index > 0 && line
            ? `  ${line}`
            : line))
            .join('\n');
        return rendered ? `* ${itemText}` : '';
    });
}
/**
 * Renders bold Markdown text.
 * @param text - Text to render.
 * @returns Bold Markdown text.
 */
export function bold(text) {
    return `**${text}**`;
}
/**
 * Renders italic Markdown text.
 * @param text - Text to render.
 * @returns Italic Markdown text.
 */
export function italic(text) {
    return `_${text}_`;
}
/**
 * Renders text inside an HTML small element.
 * @param text - Text to render.
 * @returns HTML small element.
 */
export function small(text) {
    return `<small>${text}</small>`;
}
/**
 * Creates one or more newline characters.
 * @param times - Number of newline characters to render.
 * @returns Newline characters.
 */
export function newline(times = 1) {
    return '\n'.repeat(times);
}
/**
 * Renders values without separators.
 * @param values - Values to render.
 * @returns Concatenated non-empty values.
 */
export function strings(...values) {
    return each(values, value => value, '');
}
/**
 * Renders values as Markdown blocks separated by blank lines.
 * @param values - Values to render.
 * @returns Rendered non-empty block segments.
 */
export function segments(...values) {
    return each(values, value => value, newline(2));
}
/**
 * Renders values as space-separated words.
 * @param values - Values to render.
 * @returns Rendered non-empty words.
 */
export function words(...values) {
    return each(values, value => value, ' ');
}
/**
 * Joins URL path segments and trims extra slashes around each segment.
 * @param parts - URL path segments.
 * @returns Joined URL.
 */
export function url(...parts) {
    return parts.reduce((acc, part) => {
        if (typeof part !== 'number' && !part) {
            return acc;
        }
        const segment = String(part).replace(/^\/+|\/+$/g, '');
        return acc
            ? `${acc}/${segment}`
            : segment;
    }, '');
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiZWxlbWVudHMuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi9zcmMvZWxlbWVudHMudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQUE7Ozs7R0FJRztBQUNILFNBQVMsUUFBUSxDQUFDLEtBQWlEO0lBQ2pFLE9BQU8sT0FBTyxLQUFLLEtBQUssUUFBUSxJQUFJLEtBQUssQ0FBQyxDQUFDLENBQUMsTUFBTSxDQUFDLEtBQUssQ0FBQyxDQUFDLENBQUMsQ0FBQyxFQUFFLENBQUE7QUFDaEUsQ0FBQztBQUVEOzs7Ozs7R0FNRztBQUNILE1BQU0sVUFBVSxJQUFJLENBQ2xCLEtBQXFDLEVBQ3JDLFFBQWlFLEVBQ2pFLFNBQVMsR0FBRyxPQUFPLEVBQUU7SUFFckIsT0FBTyxLQUFLO1FBQ1YsQ0FBQyxDQUFDLEtBQUssQ0FBQyxNQUFNLENBQUMsQ0FBQyxHQUFHLEVBQUUsSUFBSSxFQUFFLEVBQUU7WUFDM0IsTUFBTSxRQUFRLEdBQUcsUUFBUSxDQUFDLFFBQVEsQ0FBQyxJQUFJLENBQUMsQ0FBQyxDQUFDLElBQUksRUFBRSxDQUFBO1lBRWhELE9BQU8sR0FBRyxHQUFHLEdBQUcsR0FBRyxJQUFJLFFBQVEsQ0FBQyxDQUFDLENBQUMsU0FBUyxDQUFDLENBQUMsQ0FBQyxFQUFFLEdBQUcsUUFBUSxFQUFFLENBQUE7UUFDL0QsQ0FBQyxFQUFFLEVBQUUsQ0FBQztRQUNOLENBQUMsQ0FBQyxFQUFFLENBQUE7QUFDUixDQUFDO0FBRUQ7Ozs7O0dBS0c7QUFDSCxNQUFNLFVBQVUsT0FBTyxDQUFDLEtBQWEsRUFBRSxJQUFZO0lBQ2pELE9BQU8sR0FBRyxHQUFHLENBQUMsTUFBTSxDQUFDLEtBQUssQ0FBQyxJQUFJLElBQUksRUFBRSxDQUFBO0FBQ3ZDLENBQUM7QUFFRDs7Ozs7R0FLRztBQUNILE1BQU0sVUFBVSxJQUFJLENBQUMsSUFBWSxFQUFFLEdBQVc7SUFDNUMsT0FBTyxJQUFJLElBQUksS0FBSyxHQUFHLEdBQUcsQ0FBQTtBQUM1QixDQUFDO0FB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