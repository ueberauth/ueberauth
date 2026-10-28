import { zip as zip$1 } from "../../array/zip.mjs";
// src/fp/array/zip.ts
function zip(...arrs) {
	return function(array) {
		return zip$1(array, ...arrs);
	};
}
export { zip };
