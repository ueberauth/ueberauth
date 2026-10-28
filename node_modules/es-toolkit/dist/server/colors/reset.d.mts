/**
 * Resets every style and color set up to this point. Wraps text with the ANSI reset code.
 *
 * @param text - The text to style.
 * @returns The styled text.
 *
 * @example
 * import { colors } from 'es-toolkit/server';
 *
 * console.log(colors.reset('hello'));
 */
export declare function reset(text: string): string;