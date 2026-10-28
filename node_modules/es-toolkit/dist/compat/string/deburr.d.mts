/**
 * Converts a string by replacing special characters and diacritical marks with their ASCII equivalents.
 * For example, "Crème brûlée" becomes "Creme brulee".
 *
 * Like Lodash, only Latin-1 Supplement and Latin Extended-A letters are converted and combining
 * diacritical marks are removed. Other characters, such as Hangul, Cyrillic, or Greek letters, are kept as they are.
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
 * // Letters outside the Latin-1 Supplement and Latin Extended-A blocks are kept:
 * deburr('한국어') // returns '한국어'
 * deburr('йогурт') // returns 'йогурт'
 */
export declare function deburr(str?: string): string;