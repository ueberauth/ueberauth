//#region src/argv.ts
const ARGV_START_INDEX = 2;
/**
* Internal state of arguments.
*/
const argv = process.argv.slice(ARGV_START_INDEX);
/**
* Reset arguments state.
*/
function resetArgs() {
	argv.splice(0, argv.length);
	argv.push(...process.argv.slice(ARGV_START_INDEX));
}
/**
* Set arguments state.
* @param args
*/
function setArgs(...args) {
	argv.splice(0, argv.length);
	argv.push(...args);
}
//#endregion
//#region src/utils.ts
/**
* Match reference with argument.
* @param argRef
* @param arg
* @returns Full name or null.
*/
function matchArgName(argRef, arg) {
	if (typeof argRef === "string") return argRef === arg ? argRef : null;
	if (argRef.name === arg) return argRef.name;
	return argRef.aliases.includes(arg) ? argRef.name : null;
}
/**
* Find full argument name in references.
* @param argRefs
* @param arg
* @returns Found argument's full name or null.
*/
function findArgName(argRefs, arg) {
	let argRef;
	let argName;
	for (argRef of argRefs) {
		argName = matchArgName(argRef, arg);
		if (argName) return argName;
	}
	return null;
}
//#endregion
//#region src/core.ts
/**
* Read next argument.
* Throws error if no next argument.
* @returns Next argument.
*/
function read() {
	const value = argv.shift();
	if (!value) throw new Error("Unexpected end of arguments");
	return value;
}
/**
* Read all remaining arguments.
* @returns Remaining arguments, empty array if none.
*/
function rest() {
	return argv.splice(0, argv.length);
}
/**
* Expectation of the end.
* Throws an error if there are more arguments left.
*/
function end() {
	if (argv.length) throw new Error(`Unexpected argument "${argv[0]}"`);
}
/**
* Expect one of the given arguments.
* @param argRefs
* @returns Expected full argument name.
*/
function expect(...argRefs) {
	const arg = read();
	const argName = findArgName(argRefs, arg);
	if (!argName) throw new Error(`Unexpected argument "${arg}"`);
	return argName;
}
//#endregion
//#region src/args.ts
/**
* Describe argument with aliases.
* @param name - Main name.
* @param alias - Alias name.
* @param restAliases - Rest aliases.
* @returns Description of argument with aliases..
*/
function alias(name, alias, ...restAliases) {
	return {
		name,
		aliases: [alias, ...restAliases]
	};
}
function caseTwin(name) {
	return name.length > 1 ? name.includes("-") ? name.replace(/-+(.)/g, (_, char) => char.toUpperCase()) : name.replace(/[A-Z]/g, (char) => `-${char.toLowerCase()}`) : name;
}
/**
* Describe argument that matches both camelCase and kebab-case forms.
* Name and every alias longer than one character get the twin form as an alias.
* @param argRef - Argument name in either form.
* @returns Description of argument with the twin forms as aliases.
*/
function autocase(argRef) {
	let name;
	let aliases;
	if (typeof argRef === "string") {
		name = argRef;
		aliases = /* @__PURE__ */ new Set();
	} else {
		name = argRef.name;
		aliases = new Set(argRef.aliases.concat(argRef.aliases.map(caseTwin)));
	}
	aliases.add(caseTwin(name));
	aliases.delete(name);
	if (!aliases.size) return argRef;
	return {
		name,
		aliases: [...aliases]
	};
}
/**
* Describe option with value.
* @param argRef - Option name.
* @param type - Value type.
* @returns Option reader.
*/
function option(argRef, type) {
	if (Array.isArray(type)) return (option, read, options) => {
		const argName = matchArgName(argRef, option);
		if (argName) {
			const prevValues = options[argName];
			const value = read();
			return { [argName]: (Array.isArray(prevValues) ? prevValues : []).concat(type[0] === Number ? parseFloat(value) : value) };
		}
		return null;
	};
	if (type === String) return (option, read) => {
		const argName = matchArgName(argRef, option);
		if (argName) return { [argName]: read() };
		return null;
	};
	if (type === Number) return (option, read) => {
		const argName = matchArgName(argRef, option);
		if (argName) return { [argName]: parseFloat(read()) };
		return null;
	};
	if (type === Array) return (option, read, options) => {
		const argName = matchArgName(argRef, option);
		if (argName) {
			const prevValues = options[argName];
			const values = read().split(",");
			return { [argName]: Array.isArray(prevValues) ? prevValues.concat(values) : values };
		}
		return null;
	};
	return (option) => {
		const argName = matchArgName(argRef, option);
		if (argName) return { [argName]: true };
		return null;
	};
}
const NEGATION_PREFIX = "no-";
/**
* Describe boolean flag with `--no-*` negation support.
* @param argRef - Flag name.
* @returns Option reader.
*/
function flag(argRef) {
	return (option) => {
		let value = true;
		let argName = matchArgName(argRef, option);
		if (!argName && option.startsWith(NEGATION_PREFIX)) {
			value = false;
			argName = matchArgName(argRef, option.slice(3));
		}
		if (argName) return { [argName]: value };
		return null;
	};
}
//#endregion
//#region src/options.ts
function isOption(arg) {
	return /^--?[^-].*/.test(arg);
}
function removePrefix(arg) {
	return arg.replace(/^--?/, "");
}
function splitOption(arg) {
	const eqIndex = arg.indexOf("=");
	return eqIndex === -1 ? [arg] : [arg.slice(0, eqIndex), arg.slice(eqIndex + 1)];
}
function createOptionReader(optionReaders) {
	return optionReaders.reduceRight((readNextOption, readOption) => {
		if (!readNextOption) return readOption;
		return (option, read, options) => readOption(option, read, options) ?? readNextOption(option, read, options);
	}, null);
}
/**
* Read options from arguments.
* @param optionReaders
* @returns Options with values.
*/
function readOptions(...optionReaders) {
	if (!argv.length) return {};
	const readOption = createOptionReader(optionReaders);
	if (!readOption) return {};
	const options = {};
	let i = 0;
	let arg = argv[i];
	let optionResult;
	let optionEqValue;
	const next = () => {
		arg = argv[++i];
	};
	const remove = () => {
		if (optionEqValue !== void 0) throw new Error(`Unexpected value for "${arg}"`);
		argv.splice(i--, 1);
	};
	const read = () => {
		if (optionEqValue !== void 0) {
			const value = optionEqValue;
			optionEqValue = void 0;
			return value;
		}
		next();
		remove();
		if (!arg) throw new Error("Unexpected end of arguments");
		return arg;
	};
	while (arg) {
		if (isOption(arg)) {
			[arg, optionEqValue] = splitOption(arg);
			optionResult = readOption(removePrefix(arg), read, options);
			if (optionResult) {
				remove();
				Object.assign(options, optionResult);
			}
		}
		next();
	}
	return options;
}
//#endregion
export { alias, argv, autocase, end, expect, flag, option, read, readOptions, resetArgs, rest, setArgs };

//# sourceMappingURL=index.js.map