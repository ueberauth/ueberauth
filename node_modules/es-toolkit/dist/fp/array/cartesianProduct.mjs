import { cartesianProduct as cartesianProduct$1 } from "../../array/cartesianProduct.mjs";
// src/fp/array/cartesianProduct.ts
function cartesianProduct(...arrs) {
	return function(array) {
		return cartesianProduct$1(array, ...arrs);
	};
}
export { cartesianProduct };
