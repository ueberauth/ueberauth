import type { Arg } from './types.js';
/**
 * Format arguments.
 * @param args
 * @returns Formatted arguments.
 */
export declare function formatArgs(...args: Arg[]): string[];
/**
 * Convert value to array.
 * @param value
 * @returns Array.
 */
export declare function toArray<T>(value: T | T[]): T[];
/**
 * Check if version is a prerelease, e.g. 1.0.0-alpha.1, 1.0.0-rc.2.
 * @param version
 * @returns True if version is a prerelease.
 */
export declare function isPrereleaseVersion(version: string): boolean;
//# sourceMappingURL=utils.d.ts.map