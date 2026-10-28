import { DOMException } from "../_internal/DOMException.mjs";
/**
 * An error class representing a timeout operation.
 * @augments DOMException
 */
export declare class TimeoutError extends DOMException {
  constructor(message?: string);
}