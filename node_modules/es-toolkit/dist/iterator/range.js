const require_iterator = require("./_internal/iterator.js");
// src/iterator/range.ts
function range(start, end, step = 1) {
	if (end == null) {
		end = start;
		start = 0;
	}
	if (!Number.isInteger(step) || step === 0) throw new Error(`The step value must be a non-zero integer, but got ${step}.`);
	const finalEnd = end;
	let current = start;
	return require_iterator.iterator(function() {
		if (step > 0 ? current >= finalEnd : current <= finalEnd) return {
			value: void 0,
			done: true
		};
		const value = current;
		current += step;
		return {
			value,
			done: false
		};
	});
}
exports.range = range;
