const require_cartesianProduct = require("../../array/cartesianProduct.js");
// src/fp/array/cartesianProduct.ts
function cartesianProduct(...arrs) {
	return function(array) {
		return require_cartesianProduct.cartesianProduct(array, ...arrs);
	};
}
exports.cartesianProduct = cartesianProduct;
