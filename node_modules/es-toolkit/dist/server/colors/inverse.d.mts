/**
 * Swaps the foreground and background colors. Wraps text with ANSI codes.
 *
 * @param text - The text to style.
 * @returns The styled text.
 *
 * @example
 * import { colors } from 'es-toolkit/server';
 *
 * console.log(colors.inverse('hello'));
 */
export declare function inverse(text: string): string;