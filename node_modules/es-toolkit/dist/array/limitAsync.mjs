import { limitAsync as limitAsync$1 } from "../promise/limitAsync.mjs";
// src/array/limitAsync.ts
/**
* Wraps an async function to limit the number of concurrent executions.
*
* @deprecated Use `limitAsync` from `es-toolkit/promise` instead. This export will be removed from `es-toolkit/array` in a future major version.
*/
const limitAsync = limitAsync$1;
export { limitAsync };
