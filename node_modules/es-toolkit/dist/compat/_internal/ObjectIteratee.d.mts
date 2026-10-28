import { ObjectIterator } from "./ObjectIterator.mjs";
import { IterateeShorthand } from "./IterateeShorthand.mjs";
export type ObjectIteratee<TObject> = ObjectIterator<TObject, unknown> | IterateeShorthand<TObject[keyof TObject]>;
export type ObjectIterateeCustom<TObject, TResult> = ObjectIterator<TObject, TResult> | IterateeShorthand<TObject[keyof TObject]>;