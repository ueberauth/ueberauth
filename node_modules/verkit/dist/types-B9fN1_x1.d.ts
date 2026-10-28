import { d as VersionOptions, s as SemVer } from "./types-DFgCt4bK.js";
//#region src/comparator/types.d.ts
interface RangeOptions extends VersionOptions {
  includePrerelease?: boolean;
}
interface SemVerComparator {
  operator: "" | "<" | "<=" | ">" | ">=";
  options: RangeOptions;
  value: string;
  version: SemVer | null;
}
type ComparatorInput = SemVerComparator | string;
//#endregion
export { RangeOptions as n, SemVerComparator as r, ComparatorInput as t };