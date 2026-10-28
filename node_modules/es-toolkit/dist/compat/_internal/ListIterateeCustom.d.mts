import { ListIterator } from "./ListIterator.mjs";
import { IterateeShorthand } from "./IterateeShorthand.mjs";
export type ListIterateeCustom<T, R> = ListIterator<T, R> | IterateeShorthand<T>;