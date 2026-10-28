/**
 * Converts a string to sentence case.
 *
 * Sentence case is the naming convention in which the first character of the first word is capitalized,
 * all other characters are lowercase, and words are separated by spaces.
 *
 * @param {string} str - The string to convert.
 * @returns {string} The converted string.
 *
 * @example
 * const result1 = sentenceCase('hello world');  // result will be 'Hello world'
 * const result2 = sentenceCase('HELLO WORLD');  // result will be 'Hello world'
 * const result3 = sentenceCase('hello-world');  // result will be 'Hello world'
 * const result4 = sentenceCase('helloWorld');   // result will be 'Hello world'
 */
export declare function sentenceCase(str: string): string;