"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.emplace = emplace;
exports.getPropertyByPath = getPropertyByPath;
exports.removeUndefinedValuesFromObject = removeUndefinedValuesFromObject;
exports.isDirectory = isDirectory;
exports.isDirectorySync = isDirectorySync;
const fs_1 = __importStar(require("fs"));
/**
 * @internal
 */
function emplace(map, key, fn) {
    const cached = map.get(key);
    if (cached !== undefined) {
        return cached;
    }
    const result = fn();
    map.set(key, result);
    return result;
}
// Resolves property names or property paths defined with period-delimited
// strings or arrays of strings. Property names that are found on the source
// object are used directly (even if they include a period).
// Nested property names that include periods, within a path, are only
// understood in array paths.
/**
 * @internal
 */
function getPropertyByPath(source, path) {
    if (typeof path === 'string' &&
        Object.prototype.hasOwnProperty.call(source, path)) {
        return source[path];
    }
    const parsedPath = typeof path === 'string' ? path.split('.') : path;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return parsedPath.reduce((previous, key) => {
        if (previous === undefined) {
            return previous;
        }
        return previous[key];
    }, source);
}
/** @internal */
function removeUndefinedValuesFromObject(options) {
    return Object.fromEntries(Object.entries(options).filter(([, value]) => value !== undefined));
}
/** @internal */
/* istanbul ignore next -- @preserve */
async function isDirectory(path) {
    try {
        const stat = await fs_1.promises.stat(path);
        return stat.isDirectory();
    }
    catch (e) {
        if (e.code === 'ENOENT') {
            return false;
        }
        throw e;
    }
}
/** @internal */
/* istanbul ignore next -- @preserve */
function isDirectorySync(path) {
    try {
        const stat = fs_1.default.statSync(path);
        return stat.isDirectory();
    }
    catch (e) {
        if (e.code === 'ENOENT') {
            return false;
        }
        throw e;
    }
}
//# sourceMappingURL=util.js.map