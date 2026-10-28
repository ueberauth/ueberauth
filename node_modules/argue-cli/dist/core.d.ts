import type { ArgRef } from './types.js';
/**
 * Read next argument.
 * Throws error if no next argument.
 * @returns Next argument.
 */
export declare function read(): string;
/**
 * Read all remaining arguments.
 * @returns Remaining arguments, empty array if none.
 */
export declare function rest(): string[];
/**
 * Expectation of the end.
 * Throws an error if there are more arguments left.
 */
export declare function end(): void;
/**
 * Expect one of the given arguments.
 * @param argRefs
 * @returns Expected full argument name.
 */
export declare function expect<T extends string>(...argRefs: [...ArgRef<T>[]]): T;
//# sourceMappingURL=core.d.ts.map