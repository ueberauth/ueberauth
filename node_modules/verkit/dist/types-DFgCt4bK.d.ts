//#region src/version/types.d.ts
interface VersionOptions {
  loose?: boolean;
}
interface CoerceOptions extends VersionOptions {
  includePrerelease?: boolean;
  rtl?: boolean;
}
interface IncrementOptions extends VersionOptions {
  identifier?: string;
  identifierBase?: 0 | 1 | false;
}
type PrereleaseIdentifier = number | string;
interface SemVer {
  major: number;
  minor: number;
  patch: number;
  prerelease?: PrereleaseIdentifier[] | undefined;
  build?: string[] | undefined;
}
type VersionInput = SemVer | string;
type Comparison = -1 | 0 | 1;
type ComparisonOperator = "" | "!=" | "!==" | "<" | "<=" | "=" | "==" | "===" | ">" | ">=";
type IncrementType = "major" | "minor" | "patch" | "premajor" | "preminor" | "prepatch" | "prerelease" | "release";
type TruncationType = Exclude<IncrementType, "release">;
type VersionDifference = "major" | "minor" | "patch" | "premajor" | "preminor" | "prepatch" | "prerelease";
//#endregion
export { IncrementType as a, TruncationType as c, VersionOptions as d, IncrementOptions as i, VersionDifference as l, Comparison as n, PrereleaseIdentifier as o, ComparisonOperator as r, SemVer as s, CoerceOptions as t, VersionInput as u };