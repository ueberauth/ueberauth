import { MutableList } from "./MutableList.mjs";
import { IsWritable } from "./IsWritable.mjs";
export type RejectReadonly<T extends MutableList<unknown>> = IsWritable<T> extends true ? T : never;