/**
 * Converts a string by replacing special characters and diacritical marks with their ASCII equivalents.
 * For example, "Crème brûlée" becomes "Creme brulee".
 *
 * Only Latin letters are converted. Letters of other scripts, such as Hangul, Cyrillic, or Greek,
 * are kept as they are, even if they carry diacritical marks.
 *
 * @param str - The input string to be deburred.
 * @returns The deburred string with special characters replaced by their ASCII equivalents.
 *
 * @example
 * // Basic usage:
 * deburr('Æthelred') // returns 'Aethelred'
 *
 * @example
 * // Handling diacritical marks:
 * deburr('München') // returns 'Munchen'
 *
 * @example
 * // Special characters:
 * deburr('Crème brûlée') // returns 'Creme brulee'
 *
 * @example
 * // Letters of other scripts are kept as they are:
 * deburr('한국어') // returns '한국어'
 * deburr('йогурт') // returns 'йогурт'
 */
export declare function deburr(str: string): string;