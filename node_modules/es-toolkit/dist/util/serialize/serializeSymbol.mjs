import { serializeString } from "./serializeString.mjs";
// src/util/serialize/serializeSymbol.ts
/**
* Serializes a symbol into a string using its description.
*
* The description is quoted like any other string, so a symbol without a
* description (`Symbol()`) is distinguishable from one with an empty
* description (`Symbol('')`). Note that two different symbols with the same
* description still serialize to the same string, since a symbol's identity
* cannot be captured in a string.
*
* @param value - The symbol to serialize.
* @returns The serialized string.
*
* @example
* serializeSymbol(Symbol('test')); // "Symbol('test')"
* serializeSymbol(Symbol()); // "Symbol()"
*/
function serializeSymbol(value) {
	return value.description === void 0 ? "Symbol()" : `Symbol(${serializeString(value.description)})`;
}
export { serializeSymbol };
