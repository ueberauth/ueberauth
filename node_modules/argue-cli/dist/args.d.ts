import type { AliasArgRef, ArgRef, OptionConstructor, OptionsReaderState, OptionsReaderRead, OptionResult } from './types.js';
/**
 * Describe argument with aliases.
 * @param name - Main name.
 * @param alias - Alias name.
 * @param restAliases - Rest aliases.
 * @returns Description of argument with aliases..
 */
export declare function alias<T extends string>(name: T, alias: string, ...restAliases: string[]): AliasArgRef<T>;
/**
 * Describe argument that matches both camelCase and kebab-case forms.
 * Name and every alias longer than one character get the twin form as an alias.
 * @param argRef - Argument name in either form.
 * @returns Description of argument with the twin forms as aliases.
 */
export declare function autocase<T extends string>(argRef: ArgRef<T>): ArgRef<T>;
/**
 * Describe option with value.
 * @param argRef - Option name.
 * @param type - Value type.
 * @returns Option reader.
 */
export declare function option<T extends string, K extends OptionConstructor>(argRef: ArgRef<T>, type: K): (option: string, read: OptionsReaderRead, options: OptionsReaderState) => OptionResult<T, K> | null;
/**
 * Describe boolean flag with `--no-*` negation support.
 * @param argRef - Flag name.
 * @returns Option reader.
 */
export declare function flag<T extends string>(argRef: ArgRef<T>): (option: string) => OptionResult<T, BooleanConstructor> | null;
//# sourceMappingURL=args.d.ts.map