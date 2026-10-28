import { IterateeShorthand } from "./IterateeShorthand.js";
export type ValueKeyIteratee<T> = ((value: T, key: string) => unknown) | IterateeShorthand<T>;