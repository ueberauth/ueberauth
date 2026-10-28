import { PropertyPath } from "../types/PropertyPath.js";
export declare function propertyOf<T extends {}>(object: T): (path: PropertyPath) => any;