import { EmptyObjectOf } from "../_internal/EmptyObjectOf.js";
export declare function isEmpty<T extends {
  __trapAny: any;
}>(value?: T): boolean;
export declare function isEmpty(value: string): value is '';
export declare function isEmpty(value: Map<any, any> | Set<any> | ArrayLike<any> | null | undefined): boolean;
export declare function isEmpty(value: object): boolean;
export declare function isEmpty<T extends object>(value: T | null | undefined): value is EmptyObjectOf<T> | null | undefined;
export declare function isEmpty(value?: any): boolean;