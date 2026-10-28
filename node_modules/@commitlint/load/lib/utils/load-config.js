import path from "node:path";
import { cosmiconfig, defaultLoaders } from "cosmiconfig";
import { createJiti } from "jiti";
const moduleName = "commitlint";
const searchStrategy = "global";
export async function loadConfig(cwd, configPath) {
    let jiti;
    const tsLoader = async (filepath) => {
        jiti ??= createJiti("", { interopDefault: true });
        try {
            const result = await jiti.import(filepath);
            return result.default || result;
        }
        catch (error) {
            if (error instanceof Error) {
                error.message = `TypeScriptLoader failed to compile TypeScript:\n${error.message}`;
            }
            throw error;
        }
    };
    const explorer = cosmiconfig(moduleName, {
        searchStrategy,
        searchPlaces: [
            // cosmiconfig overrides default searchPlaces if any new search place is added (For e.g. `*.ts` files),
            // we need to manually merge default searchPlaces from https://github.com/davidtheclark/cosmiconfig#searchplaces
            "package.json",
            "package.yaml",
            `.${moduleName}rc`,
            `.${moduleName}rc.json`,
            `.${moduleName}rc.yaml`,
            `.${moduleName}rc.yml`,
            `.${moduleName}rc.js`,
            `.${moduleName}rc.cjs`,
            `.${moduleName}rc.mjs`,
            `${moduleName}.config.js`,
            `${moduleName}.config.cjs`,
            `${moduleName}.config.mjs`,
            // files supported by TypescriptLoader
            `.${moduleName}rc.ts`,
            `.${moduleName}rc.cts`,
            `.${moduleName}rc.mts`,
            `${moduleName}.config.ts`,
            `${moduleName}.config.cts`,
            `${moduleName}.config.mts`,
        ],
        loaders: {
            ".ts": tsLoader,
            ".cts": tsLoader,
            ".mts": tsLoader,
            ".cjs": defaultLoaders[".cjs"],
            ".js": defaultLoaders[".js"],
        },
    });
    const explicitPath = configPath ? path.resolve(cwd, configPath) : undefined;
    const explore = explicitPath ? explorer.load : explorer.search;
    const searchPath = explicitPath ? explicitPath : cwd;
    const local = await explore(searchPath);
    if (local) {
        return local;
    }
    return null;
}
//# sourceMappingURL=load-config.js.map