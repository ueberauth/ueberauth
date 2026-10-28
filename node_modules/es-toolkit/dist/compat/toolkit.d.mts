import { compat_d_exports } from "./compat.mjs";
type ToolkitFn = (value: any) => any;
type Compat = typeof compat_d_exports;
export interface Toolkit extends ToolkitFn, Compat {}
export declare const toolkit: Toolkit;
export {};