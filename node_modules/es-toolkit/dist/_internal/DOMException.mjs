import { globalThis as globalThis_ } from "./globalThis.mjs";
// src/_internal/DOMException.ts
const DOMException = typeof globalThis_.DOMException !== "undefined" ? globalThis_.DOMException : Error;
export { DOMException };
