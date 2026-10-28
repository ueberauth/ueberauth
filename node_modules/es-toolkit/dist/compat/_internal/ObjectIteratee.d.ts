import { ObjectIterator } from "./ObjectIterator.js";
import { IterateeShorthand } from "./IterateeShorthand.js";
export type ObjectIteratee<TObject> = ObjectIterator<TObject, unknown> | IterateeShorthand<TObject[keyof TObject]>;
export type ObjectIterateeCustom<TObject, TResult> = ObjectIterator<TObject, TResult> | IterateeShorthand<TObject[keyof TObject]>;