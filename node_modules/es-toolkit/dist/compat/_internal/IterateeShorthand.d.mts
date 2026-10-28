import { PartialShallow } from "./PartialShallow.mjs";
export type IterateeShorthand<T> = PropertyKey | [PropertyKey, any] | PartialShallow<T>;