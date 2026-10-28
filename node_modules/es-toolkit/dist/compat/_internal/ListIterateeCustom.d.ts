import { ListIterator } from "./ListIterator.js";
import { IterateeShorthand } from "./IterateeShorthand.js";
export type ListIterateeCustom<T, R> = ListIterator<T, R> | IterateeShorthand<T>;