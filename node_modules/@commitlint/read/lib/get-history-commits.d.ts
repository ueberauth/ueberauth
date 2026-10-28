import { type GitLogParams } from "@conventional-changelog/git-client";
export type HistoryCommitsOptions = GitLogParams & Record<string, unknown>;
export declare function getHistoryCommits(options: HistoryCommitsOptions, opts?: {
    cwd?: string;
}): Promise<string[]>;
//# sourceMappingURL=get-history-commits.d.ts.map