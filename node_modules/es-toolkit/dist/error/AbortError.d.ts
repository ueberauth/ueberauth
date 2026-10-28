import { DOMException } from "../_internal/DOMException.js";
/**
 * An error class representing an aborted operation.
 * @augments DOMException
 */
export declare class AbortError extends DOMException {
  constructor(message?: string);
}