import type { OptionReader } from './types.js';
import type { Merge, ReturnTypes } from './utils.js';
/**
 * Read options from arguments.
 * @param optionReaders
 * @returns Options with values.
 */
export declare function readOptions<T extends OptionReader[]>(...optionReaders: [...T]): Partial<Merge<ReturnTypes<T>>>;
//# sourceMappingURL=options.d.ts.map