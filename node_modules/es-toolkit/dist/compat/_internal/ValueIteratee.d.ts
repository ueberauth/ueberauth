import { PartialShallow } from "./PartialShallow.js";
export type ValueIteratee<T> = ((value: T) => unknown) | (PropertyKey | [PropertyKey, any] | PartialShallow<T>);