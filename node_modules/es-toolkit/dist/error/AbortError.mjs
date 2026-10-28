import { DOMException } from "../_internal/DOMException.mjs";
// src/error/AbortError.ts
/**
* An error class representing an aborted operation.
* @augments DOMException
*/
var AbortError = class extends DOMException {
	constructor(message = "The operation was aborted") {
		super(message);
	}
};
export { AbortError };
