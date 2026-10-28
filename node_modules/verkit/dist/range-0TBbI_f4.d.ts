import { s as SemVer, u as VersionInput } from "./types-DFgCt4bK.js";
import { n as RangeOptions, r as SemVerComparator } from "./types-B9fN1_x1.js";
//#region src/range/types.d.ts
interface SemVerRange {
  options: RangeOptions;
  sets: SemVerComparator[][];
}
type RangeInput = SemVerRange | string;
type RangeDirection = "<" | ">";
//#endregion
//#region src/range/operations.d.ts
declare function isValidRange(range: string, options?: RangeOptions): boolean;
declare function isValidRange(range: RangeInput): boolean;
declare function normalizeRange(range: string, options?: RangeOptions): string | null;
declare function normalizeRange(range: RangeInput): string | null;
declare function satisfies(version: VersionInput, range: string, options?: RangeOptions): boolean;
declare function satisfies(version: VersionInput, range: RangeInput): boolean;
declare function rangeToComparators(range: string, options?: RangeOptions): string[][];
declare function rangeToComparators(range: RangeInput): string[][];
declare function findMaxSatisfying<T extends VersionInput>(versions: readonly T[], range: string, options?: RangeOptions): T | null;
declare function findMaxSatisfying<T extends VersionInput>(versions: readonly T[], range: RangeInput): T | null;
declare function findMinSatisfying<T extends VersionInput>(versions: readonly T[], range: string, options?: RangeOptions): T | null;
declare function findMinSatisfying<T extends VersionInput>(versions: readonly T[], range: RangeInput): T | null;
declare function findMinimumForRange(range: string, options?: RangeOptions): SemVer | null;
declare function findMinimumForRange(range: RangeInput): SemVer | null;
declare function isOutsideRange(version: VersionInput, range: string, direction: RangeDirection, options?: RangeOptions): boolean;
declare function isOutsideRange(version: VersionInput, range: RangeInput, direction: RangeDirection): boolean;
declare function isGreaterThanRange(version: VersionInput, range: string, options?: RangeOptions): boolean;
declare function isGreaterThanRange(version: VersionInput, range: RangeInput): boolean;
declare function isLessThanRange(version: VersionInput, range: string, options?: RangeOptions): boolean;
declare function isLessThanRange(version: VersionInput, range: RangeInput): boolean;
declare function rangesIntersect(left: string, right: string, options?: RangeOptions): boolean;
declare function rangesIntersect(left: RangeInput, right: RangeInput): boolean;
declare function simplifyRange<T extends VersionInput>(versions: readonly T[], range: string, options?: RangeOptions): string;
declare function simplifyRange<T extends VersionInput>(versions: readonly T[], range: RangeInput): string;
//#endregion
//#region src/range/parse.d.ts
declare function parseRange(range: string, options?: RangeOptions): SemVerRange;
declare function parseRange(range: RangeInput): SemVerRange;
declare function tryParseRange(range: string, options?: RangeOptions): SemVerRange | null;
declare function tryParseRange(range: RangeInput): SemVerRange | null;
//#endregion
//#region src/range/subset.d.ts
declare function isRangeSubset(subset: string, superset: string, options?: RangeOptions): boolean;
declare function isRangeSubset(subset: RangeInput, superset: RangeInput): boolean;
//#endregion
export { RangeInput as _, findMinSatisfying as a, isLessThanRange as c, normalizeRange as d, rangeToComparators as f, RangeDirection as g, simplifyRange as h, findMaxSatisfying as i, isOutsideRange as l, satisfies as m, parseRange as n, findMinimumForRange as o, rangesIntersect as p, tryParseRange as r, isGreaterThanRange as s, isRangeSubset as t, isValidRange as u, SemVerRange as v };