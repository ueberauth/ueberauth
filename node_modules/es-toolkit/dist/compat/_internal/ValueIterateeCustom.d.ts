import { IterateeShorthand } from "./IterateeShorthand.js";
export type ValueIterateeCustom<T, TResult> = ((value: T) => TResult) | IterateeShorthand<T>;