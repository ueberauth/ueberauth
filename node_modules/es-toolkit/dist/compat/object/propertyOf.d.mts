import { PropertyPath } from "../types/PropertyPath.mjs";
export declare function propertyOf<T extends {}>(object: T): (path: PropertyPath) => any;