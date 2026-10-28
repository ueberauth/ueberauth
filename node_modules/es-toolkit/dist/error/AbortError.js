const require_DOMException = require("../_internal/DOMException.js");
// src/error/AbortError.ts
/**
* An error class representing an aborted operation.
* @augments DOMException
*/
var AbortError = class extends require_DOMException.DOMException {
	constructor(message = "The operation was aborted") {
		super(message);
	}
};
exports.AbortError = AbortError;
