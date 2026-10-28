import { u as VersionInput } from "./types-DFgCt4bK.js";
import { n as RangeOptions, r as SemVerComparator, t as ComparatorInput } from "./types-B9fN1_x1.js";
//#region src/comparator/operations.d.ts
declare function normalizeComparator(comparator: string, options?: RangeOptions): string;
declare function normalizeComparator(comparator: ComparatorInput): string;
declare function satisfiesComparator(version: VersionInput, comparator: string, options?: RangeOptions): boolean;
declare function satisfiesComparator(version: VersionInput, comparator: ComparatorInput): boolean;
declare function comparatorsIntersect(left: string, right: string, options?: RangeOptions): boolean;
declare function comparatorsIntersect(left: ComparatorInput, right: ComparatorInput): boolean;
//#endregion
//#region src/comparator/parse.d.ts
declare function parseComparator(comparator: string, options?: RangeOptions): SemVerComparator;
declare function parseComparator(comparator: ComparatorInput): SemVerComparator;
declare function tryParseComparator(comparator: string, options?: RangeOptions): SemVerComparator | null;
declare function tryParseComparator(comparator: ComparatorInput): SemVerComparator | null;
//#endregion
export { satisfiesComparator as a, normalizeComparator as i, tryParseComparator as n, comparatorsIntersect as r, parseComparator as t };