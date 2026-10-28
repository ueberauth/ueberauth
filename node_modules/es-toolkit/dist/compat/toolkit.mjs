import { compat_exports } from "./compat.mjs";
// src/compat/toolkit.ts
const toolkit = ((value) => {
	return value;
});
Object.assign(toolkit, compat_exports);
toolkit.partial.placeholder = toolkit;
toolkit.partialRight.placeholder = toolkit;
export { toolkit };
