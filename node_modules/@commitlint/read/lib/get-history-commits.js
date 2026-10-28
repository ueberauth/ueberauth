import { GitClient } from "@conventional-changelog/git-client";
// Get commit messages from history
export async function getHistoryCommits(options, opts = {}) {
    // Note: @conventional-changelog/git-client doesn't support arbitrary git
    // log arguments. We extract and handle 'skip' manually here to preserve
    // backward compatibility. Other arbitrary arguments passed via gitLogArgs
    // may be silently ignored.
    const { skip: skipRaw, ...gitOptions } = options;
    let skipNum = 0;
    if (skipRaw !== undefined) {
        skipNum = Number(skipRaw);
        if (!Number.isInteger(skipNum) || skipNum < 0) {
            throw new TypeError(`Invalid skip value: ${skipRaw}`);
        }
    }
    const client = new GitClient(opts.cwd ?? process.cwd());
    const data = [];
    for await (const commit of client.getRawCommits(gitOptions)) {
        if (skipNum > 0) {
            skipNum--;
            continue;
        }
        data.push(commit);
    }
    return data;
}
//# sourceMappingURL=get-history-commits.js.map