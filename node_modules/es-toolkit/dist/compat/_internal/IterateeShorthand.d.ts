import { PartialShallow } from "./PartialShallow.js";
export type IterateeShorthand<T> = PropertyKey | [PropertyKey, any] | PartialShallow<T>;