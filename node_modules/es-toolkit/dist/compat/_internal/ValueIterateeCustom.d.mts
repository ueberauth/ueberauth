import { IterateeShorthand } from "./IterateeShorthand.mjs";
export type ValueIterateeCustom<T, TResult> = ((value: T) => TResult) | IterateeShorthand<T>;