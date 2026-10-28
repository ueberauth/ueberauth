import { PropertyPath } from "../types/PropertyPath.mjs";
export declare function property<T, R>(path: PropertyPath): (obj: T) => R;