const require_DOMException = require("../_internal/DOMException.js");
// src/error/TimeoutError.ts
/**
* An error class representing a timeout operation.
* @augments DOMException
*/
var TimeoutError = class extends require_DOMException.DOMException {
	constructor(message = "The operation was timed out") {
		super(message);
	}
};
exports.TimeoutError = TimeoutError;
