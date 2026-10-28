type ReplaceFunction = (match: string, ...args: any[]) => string;
export declare function replace(string: string, pattern: RegExp | string, replacement: ReplaceFunction | string): string;
export declare function replace(pattern: RegExp | string, replacement: ReplaceFunction | string): string;
export {};