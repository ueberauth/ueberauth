import { RecursiveArray } from "./RecursiveArray.js";
export interface ListOfRecursiveArraysOrValues<T> extends ArrayLike<T | RecursiveArray<T>> {}