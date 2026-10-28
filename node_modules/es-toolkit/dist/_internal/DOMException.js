const require_globalThis = require("./globalThis.js");
// src/_internal/DOMException.ts
const DOMException = typeof require_globalThis.globalThis.DOMException !== "undefined" ? require_globalThis.globalThis.DOMException : Error;
exports.DOMException = DOMException;
