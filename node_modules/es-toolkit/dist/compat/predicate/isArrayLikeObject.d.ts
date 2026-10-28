export declare function isArrayLikeObject<T extends {
  __lodashAnyHack: any;
}>(value: T): boolean;
export declare function isArrayLikeObject(value: ((...args: any[]) => any) | Function | string | boolean | number | null | undefined): value is never;
export declare function isArrayLikeObject(value: any): value is object & {
  length: number;
};