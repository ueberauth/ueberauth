const require_words = require("./words.js");
// src/string/sentenceCase.ts
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
function sentenceCase(str) {
	const words$1 = require_words.words(str.trim());
	let result = "";
	for (let i = 0; i < words$1.length; i++) {
		const word = words$1[i];
		if (i === 0) result += word[0].toUpperCase() + word.slice(1).toLowerCase();
		else result += " " + word.toLowerCase();
	}
	return result;
}
exports.sentenceCase = sentenceCase;
