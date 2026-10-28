import { DOMException } from "../_internal/DOMException.mjs";
// src/error/TimeoutError.ts
/**
* An error class representing a timeout operation.
* @augments DOMException
*/
var TimeoutError = class extends DOMException {
	constructor(message = "The operation was timed out") {
		super(message);
	}
};
export { TimeoutError };
