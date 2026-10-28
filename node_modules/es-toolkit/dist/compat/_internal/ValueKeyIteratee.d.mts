import { IterateeShorthand } from "./IterateeShorthand.mjs";
export type ValueKeyIteratee<T> = ((value: T, key: string) => unknown) | IterateeShorthand<T>;