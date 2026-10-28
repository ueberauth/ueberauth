const require_toString = require("../util/toString.js");
const require_isIterateeCall = require("../_internal/isIterateeCall.js");
const require_attempt = require("../function/attempt.js");
const require_defaults = require("../object/defaults.js");
const require_escape = require("./escape.js");
// src/compat/string/template.ts
const esTemplateRegExp = /\$\{([^\\}]*(?:\\.[^\\}]*)*)\}/g;
const unEscapedRegExp = /['\n\r\u2028\u2029\\]/g;
const noMatchExp = /($^)/;
const escapeMap = /* @__PURE__ */ new Map([
	["\\", "\\"],
	["'", "'"],
	["\n", "n"],
	["\r", "r"],
	["\u2028", "u2028"],
	["\u2029", "u2029"]
]);
function escapeString(match) {
	return `\\${escapeMap.get(match)}`;
}
const defaultInterpolateRegExp = /<%=([\s\S]+?)%>/g;
const templateSettings = {
	escape: /<%-([\s\S]+?)%>/g,
	evaluate: /<%([\s\S]+?)%>/g,
	interpolate: defaultInterpolateRegExp,
	variable: "",
	imports: { _: {
		escape: require_escape.escape,
		template
	} }
};
/**
* Compiles a template string into a function that can interpolate data properties.
*
* This function allows you to create a template with custom delimiters for escaping,
* evaluating, and interpolating values. It can also handle custom variable names and
* imported functions.
*
* @param string - The template string.
* @param [options] - The options object.
* @param [options.escape] - The regular expression for "escape" delimiter.
* @param [options.evaluate] - The regular expression for "evaluate" delimiter.
* @param [options.interpolate] - The regular expression for "interpolate" delimiter.
* @param [options.variable] - The data object variable name.
* @param [options.imports] - The object of imported functions.
* @param [options.sourceURL] - The source URL of the template.
* @param [guard] - The guard to detect if the function is called with `options`.
* @returns Returns the compiled template function.
*
* @example
* // Use the "escape" delimiter to escape data properties.
* const compiled = template('<%- value %>');
* compiled({ value: '<div>' }); // returns '&lt;div&gt;'
*
* @example
* // Use the "interpolate" delimiter to interpolate data properties.
* const compiled = template('<%= value %>');
* compiled({ value: 'Hello, World!' }); // returns 'Hello, World!'
*
* @example
* // Use the "evaluate" delimiter to evaluate JavaScript code.
* const compiled = template('<% if (value) { %>Yes<% } else { %>No<% } %>');
* compiled({ value: true }); // returns 'Yes'
*
* @example
* // Use the "variable" option to specify the data object variable name.
* const compiled = template('<%= data.value %>', { variable: 'data' });
* compiled({ value: 'Hello, World!' }); // returns 'Hello, World!'
*
* @example
* // Use the "imports" option to import functions.
* const compiled = template('<%= _.toUpper(value) %>', { imports: { _: { toUpper } } });
* compiled({ value: 'hello, world!' }); // returns 'HELLO, WORLD!'
*
* @example
* // Use the custom "escape" delimiter.
* const compiled = template('<@ value @>', { escape: /<@([\s\S]+?)@>/g });
* compiled({ value: '<div>' }); // returns '&lt;div&gt;'
*
* @example
* // Use the custom "evaluate" delimiter.
* const compiled = template('<# if (value) { #>Yes<# } else { #>No<# } #>', { evaluate: /<#([\s\S]+?)#>/g });
* compiled({ value: true }); // returns 'Yes'
*
* @example
* // Use the custom "interpolate" delimiter.
* const compiled = template('<$ value $>', { interpolate: /<\$([\s\S]+?)\$>/g });
* compiled({ value: 'Hello, World!' }); // returns 'Hello, World!'
*
* @example
* // Use the "sourceURL" option to specify the source URL of the template.
* const compiled = template('hello <%= user %>!', { sourceURL: 'template.js' });
*/
function template(string, options, guard) {
	var _options$escape$sourc, _options$escape, _options$interpolate$, _options$interpolate, _options$evaluate$sou, _options$evaluate;
	string = require_toString.toString(string);
	if (guard && require_isIterateeCall.isIterateeCall(string, options, guard)) options = templateSettings;
	options = require_defaults.defaults(Object.assign({}, options), templateSettings);
	const delimitersRegExp = new RegExp([
		(_options$escape$sourc = (_options$escape = options.escape) === null || _options$escape === void 0 ? void 0 : _options$escape.source) !== null && _options$escape$sourc !== void 0 ? _options$escape$sourc : noMatchExp.source,
		(_options$interpolate$ = (_options$interpolate = options.interpolate) === null || _options$interpolate === void 0 ? void 0 : _options$interpolate.source) !== null && _options$interpolate$ !== void 0 ? _options$interpolate$ : noMatchExp.source,
		options.interpolate === defaultInterpolateRegExp ? esTemplateRegExp.source : noMatchExp.source,
		(_options$evaluate$sou = (_options$evaluate = options.evaluate) === null || _options$evaluate === void 0 ? void 0 : _options$evaluate.source) !== null && _options$evaluate$sou !== void 0 ? _options$evaluate$sou : noMatchExp.source,
		"$"
	].join("|"), "g");
	let lastIndex = 0;
	let isEvaluated = false;
	let source = `__p += ''`;
	let match = delimitersRegExp.exec(string);
	while (match !== null) {
		const [fullMatch, escapeValue, interpolateValue, esTemplateValue, evaluateValue] = match;
		const { index } = match;
		source += ` + '${string.slice(lastIndex, index).replace(unEscapedRegExp, escapeString)}'`;
		if (escapeValue) source += ` + _.escape(${escapeValue})`;
		if (interpolateValue) source += ` + ((${interpolateValue}) == null ? '' : ${interpolateValue})`;
		else if (esTemplateValue) source += ` + ((${esTemplateValue}) == null ? '' : ${esTemplateValue})`;
		if (evaluateValue) {
			source += `;\n${evaluateValue};\n __p += ''`;
			isEvaluated = true;
		}
		lastIndex = index + fullMatch.length;
		if (fullMatch.length === 0) delimitersRegExp.lastIndex++;
		match = delimitersRegExp.exec(string);
	}
	const imports = require_defaults.defaults(Object.assign({}, options.imports), templateSettings.imports);
	const importsKeys = Object.keys(imports);
	const importValues = importsKeys.map((key) => imports[key]);
	const sourceURL = `//# sourceURL=${options.sourceURL ? String(options.sourceURL).replace(/[\r\n]/g, " ") : `es-toolkit.templateSource[${Date.now()}]`}\n`;
	const compiledFunction = `function(${options.variable || "obj"}) {
    let __p = '';
    ${options.variable ? "" : "if (obj == null) { obj = {}; }"}
    ${isEvaluated ? `function print() { __p += Array.prototype.join.call(arguments, ''); }` : ""}
    ${options.variable ? source : `with(obj) {\n${source}\n}`}
    return __p;
  }`;
	const result = require_attempt.attempt(() => new Function(...importsKeys, `${sourceURL}return ${compiledFunction}`)(...importValues));
	result.source = compiledFunction;
	if (result instanceof Error) throw result;
	return result;
}
exports.template = template;
exports.templateSettings = templateSettings;
