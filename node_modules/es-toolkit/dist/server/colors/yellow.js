const require_wrapAnsi = require("./_internal/wrapAnsi.js");
// src/server/colors/yellow.ts
/**
* Yellow foreground. Wraps text with ANSI codes.
*
* @param text - The text to style.
* @returns The styled text.
*
* @example
* import { colors } from 'es-toolkit/server';
*
* console.log(colors.yellow('hello'));
*/
function yellow(text) {
	return require_wrapAnsi.wrapAnsi("\x1B[33m", "\x1B[39m", text);
}
exports.yellow = yellow;
