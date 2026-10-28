import { a as IncrementType, c as TruncationType, d as VersionOptions, i as IncrementOptions, l as VersionDifference, n as Comparison, o as PrereleaseIdentifier, r as ComparisonOperator, s as SemVer, t as CoerceOptions, u as VersionInput } from "./types-DFgCt4bK.js";
//#region src/version/comparison.d.ts
declare function compare(left: VersionInput, right: VersionInput, options?: VersionOptions): Comparison;
declare function compareReversed(left: VersionInput, right: VersionInput, options?: VersionOptions): Comparison;
declare function compareMain(left: VersionInput, right: VersionInput, options?: VersionOptions): Comparison;
declare function comparePrerelease(left: VersionInput, right: VersionInput, options?: VersionOptions): Comparison;
declare function compareBuild(left: VersionInput, right: VersionInput, options?: VersionOptions): Comparison;
declare function compareWithOperator(left: VersionInput, operator: ComparisonOperator, right: VersionInput, options?: VersionOptions): boolean;
declare function isEqual(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function isNotEqual(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function isGreaterThan(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function isGreaterThanOrEqual(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function isLessThan(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function isLessThanOrEqual(left: VersionInput, right: VersionInput, options?: VersionOptions): boolean;
declare function sort<T extends VersionInput>(versions: readonly T[], options?: VersionOptions): T[];
declare function sortReversed<T extends VersionInput>(versions: readonly T[], options?: VersionOptions): T[];
//#endregion
//#region src/version/constants.d.ts
declare const SEMVER_SPEC_VERSION: string;
declare const INCREMENT_TYPES: readonly IncrementType[];
declare const TRUNCATION_TYPES: readonly TruncationType[];
//#endregion
//#region src/version/identifiers.d.ts
declare function compareIdentifiers(left: PrereleaseIdentifier, right: PrereleaseIdentifier): Comparison;
declare function compareIdentifiersReversed(left: PrereleaseIdentifier, right: PrereleaseIdentifier): Comparison;
//#endregion
//#region src/version/operations.d.ts
declare function isValid(version: VersionInput, options?: VersionOptions): boolean;
declare function isPrerelease(version: VersionInput, options?: VersionOptions): boolean | null;
declare function isStable(version: VersionInput, options?: VersionOptions): boolean | null;
declare function normalizeFull(version: VersionInput, options?: VersionOptions): string | null;
declare function normalize(version: VersionInput, options?: VersionOptions): string | null;
declare function clean(version: VersionInput, options?: VersionOptions): string | null;
declare function coerce(value: number | VersionInput, options?: CoerceOptions): SemVer | null;
declare function increment(version: VersionInput, release: IncrementType, options?: IncrementOptions): string | null;
declare function truncate(version: VersionInput, truncation: TruncationType, options?: VersionOptions): string | null;
declare function difference(left: VersionInput, right: VersionInput): VersionDifference | null;
declare function getMajor(version: VersionInput, options?: VersionOptions): number;
declare function getMinor(version: VersionInput, options?: VersionOptions): number;
declare function getPatch(version: VersionInput, options?: VersionOptions): number;
declare function getPrerelease(version: VersionInput, options?: VersionOptions): PrereleaseIdentifier[] | null;
declare function getBuild(version: VersionInput, options?: VersionOptions): string[] | null;
//#endregion
//#region src/version/parse.d.ts
declare function parse(version: VersionInput, options?: VersionOptions): SemVer;
declare function tryParse(version: VersionInput, options?: VersionOptions): SemVer | null;
//#endregion
export { isGreaterThan as A, compare as C, compareReversed as D, comparePrerelease as E, sort as F, sortReversed as I, isLessThan as M, isLessThanOrEqual as N, compareWithOperator as O, isNotEqual as P, TRUNCATION_TYPES as S, compareMain as T, truncate as _, difference as a, INCREMENT_TYPES as b, getMinor as c, increment as d, isPrerelease as f, normalizeFull as g, normalize as h, coerce as i, isGreaterThanOrEqual as j, isEqual as k, getPatch as l, isValid as m, tryParse as n, getBuild as o, isStable as p, clean as r, getMajor as s, parse as t, getPrerelease as u, compareIdentifiers as v, compareBuild as w, SEMVER_SPEC_VERSION as x, compareIdentifiersReversed as y };