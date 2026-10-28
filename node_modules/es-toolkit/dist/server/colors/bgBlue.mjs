import { wrapAnsiBg } from "./_internal/wrapAnsiBg.mjs";
// src/server/colors/bgBlue.ts
/**
* Blue background. Wraps text with ANSI codes.
*
* @param text - The text to style.
* @returns The styled text.
*
* @example
* import { colors } from 'es-toolkit/server';
*
* console.log(colors.bgBlue('hello'));
*/
function bgBlue(text) {
	return wrapAnsiBg("\x1B[44m", "\x1B[49m", text);
}
export { bgBlue };
