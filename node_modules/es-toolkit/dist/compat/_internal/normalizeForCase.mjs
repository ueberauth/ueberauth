import { toString } from "../util/toString.mjs";
// src/compat/_internal/normalizeForCase.ts
function normalizeForCase(str) {
	if (typeof str !== "string") str = toString(str);
	return str.replace(/['\u2019]/g, "");
}
export { normalizeForCase };
