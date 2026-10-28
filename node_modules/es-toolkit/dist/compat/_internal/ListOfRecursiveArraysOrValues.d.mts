import { RecursiveArray } from "./RecursiveArray.mjs";
export interface ListOfRecursiveArraysOrValues<T> extends ArrayLike<T | RecursiveArray<T>> {}