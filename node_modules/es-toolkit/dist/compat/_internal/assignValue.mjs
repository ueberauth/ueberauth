import { eq } from "../util/eq.mjs";
import { hasOwn } from "./hasOwn.mjs";
// src/compat/_internal/assignValue.ts
const assignValue = (object, key, value) => {
	const objValue = object[key];
	if (!(hasOwn(object, key) && eq(objValue, value)) || value === void 0 && !(key in object)) object[key] = value;
};
export { assignValue };
