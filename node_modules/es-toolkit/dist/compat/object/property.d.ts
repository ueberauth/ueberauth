import { PropertyPath } from "../types/PropertyPath.js";
export declare function property<T, R>(path: PropertyPath): (obj: T) => R;