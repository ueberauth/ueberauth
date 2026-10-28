const require_compat = require("./compat.js");
// src/compat/toolkit.ts
const toolkit = ((value) => {
	return value;
});
Object.assign(toolkit, require_compat.compat_exports);
toolkit.partial.placeholder = toolkit;
toolkit.partialRight.placeholder = toolkit;
exports.toolkit = toolkit;
