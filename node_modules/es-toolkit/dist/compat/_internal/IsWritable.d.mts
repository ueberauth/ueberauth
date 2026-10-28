import { Equals } from "./Equals.mjs";
export type IsWritable<T> = Equals<{ [K in keyof T]: T[K]; }, { -readonly [K in keyof T]: T[K]; }>;