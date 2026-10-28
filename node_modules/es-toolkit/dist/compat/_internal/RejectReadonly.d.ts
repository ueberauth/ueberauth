import { MutableList } from "./MutableList.js";
import { IsWritable } from "./IsWritable.js";
export type RejectReadonly<T extends MutableList<unknown>> = IsWritable<T> extends true ? T : never;