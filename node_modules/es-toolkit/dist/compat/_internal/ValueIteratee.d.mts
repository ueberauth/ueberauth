import { PartialShallow } from "./PartialShallow.mjs";
export type ValueIteratee<T> = ((value: T) => unknown) | (PropertyKey | [PropertyKey, any] | PartialShallow<T>);