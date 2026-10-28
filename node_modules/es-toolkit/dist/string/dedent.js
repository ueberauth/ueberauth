// src/string/dedent.ts
function dedent(str, ...values) {
	switch (typeof str) {
		case "function": return function(strings, ...args) {
			return str(dedentTemplateStringsArray(strings), ...args);
		};
		case "string": return dedentImpl(str);
		default: {
			const parts = dedentParts(str);
			let text = parts[0];
			for (let i = 0; i < values.length; i++) text += String(values[i]) + parts[i + 1];
			return text;
		}
	}
}
function dedentTemplateStringsArray(strings) {
	const parts = dedentParts(strings);
	return Object.assign(parts, { raw: parts });
}
/**
* Dedents the static parts of a template literal as a whole, without letting the
* interpolated values take part in the indentation calculation.
*
* Each interpolation is temporarily replaced by a placeholder that contains no
* whitespace or line break, so it counts as regular content of its line just
* like the substituted value would.
*/
function dedentParts(strings) {
	assertTemplateShape(strings);
	const parts = Array.from(strings);
	if (parts.length === 1) return [dedentImpl(parts[0])];
	let placeholder = "\0";
	const joinedParts = parts.join("");
	while (joinedParts.includes(placeholder)) placeholder += "\0";
	return dedentImpl(parts.join(placeholder)).split(placeholder);
}
/**
* Checks that a template literal has the shape `String.dedent` requires.
*
* Only the static parts of the template are inspected, so interpolated values
* never affect the check. The opening line must end with a newline and the closing
* line must be preceded by one, and both may contain only whitespace.
*/
function assertTemplateShape(strings) {
	const first = strings[0];
	const openingLineEnd = first.indexOf("\n");
	if (openingLineEnd === -1 || first.slice(0, openingLineEnd).trim() !== "") throw new TypeError("Invalid opening line.");
	const last = strings[strings.length - 1];
	const closingLineStart = last.lastIndexOf("\n");
	if (closingLineStart === -1 || last.slice(closingLineStart + 1).trim() !== "") throw new TypeError("Invalid closing line.");
}
function dedentImpl(text) {
	text = text.replace(/\r\n/g, "\n");
	const lines = text.split("\n");
	if (lines.length > 0 && lines[0].trim() === "") lines.shift();
	if (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop();
	let commonIndent = Infinity;
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (line.trim() === "") continue;
		let indent = 0;
		while (indent < line.length && (line[indent] === " " || line[indent] === "	")) indent++;
		if (indent < commonIndent) commonIndent = indent;
	}
	if (commonIndent === Infinity) return "";
	for (let i = 0; i < lines.length; i++) if (lines[i].trim() === "") lines[i] = "";
	else lines[i] = lines[i].slice(commonIndent);
	return lines.join("\n");
}
exports.dedent = dedent;
