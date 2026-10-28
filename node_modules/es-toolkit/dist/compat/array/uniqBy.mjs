import { uniqBy as uniqBy$1 } from "../../array/uniqBy.mjs";
import { ary } from "../../function/ary.mjs";
import { identity } from "../../function/identity.mjs";
import { isArrayLike } from "../predicate/isArrayLike.mjs";
import { iteratee } from "../util/iteratee.mjs";
import { normalizeZero } from "../_internal/normalizeZero.mjs";
// src/compat/array/uniqBy.ts
function uniqBy(array, iteratee$1 = identity) {
	if (!isArrayLike(array)) return [];
	return uniqBy$1(Array.from(array), ary(iteratee(iteratee$1), 1)).map(normalizeZero);
}
export { uniqBy };
