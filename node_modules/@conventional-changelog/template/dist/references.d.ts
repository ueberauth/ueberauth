import type { CommitKnownProps, FinalTemplateContext } from './types/index.js';
export interface IssueReference {
    /**
     * Issue prefix. EG: In `gh-123` `gh-` is the prefix.
     */
    prefix: string;
    /**
     * Issue id. EG: In `gh-123` `123` is the id.
     */
    issue: string;
}
export interface ReferencesFormatterOptions<Commit extends CommitKnownProps = CommitKnownProps> {
    /**
     * The prefixes of an issue. EG: In `gh-123` `gh-` is the prefix.
     * Prefixes are matched in the given order, so a prefix which starts
     * with another one should be placed first.
     */
    issuePrefixes?: (string | RegExp)[];
    /**
     * Pattern of an issue id. EG: In `gh-123` `123` is the id.
     */
    issuePattern?: RegExp;
    /**
     * Builds an issue URL. Empty result leaves the reference as is.
     */
    formatIssueUrl(context: FinalTemplateContext<Commit>, reference: IssueReference): string;
    /**
     * Builds a user URL. Empty result leaves the mention as is.
     */
    formatUserUrl(context: FinalTemplateContext<Commit>, user: string): string;
}
export type ReferencesFormatter<Commit extends CommitKnownProps = CommitKnownProps> = (text: string, context: FinalTemplateContext<Commit>, references?: string[]) => string;
/**
 * Creates a text formatter for the given options.
 *
 * Regexes from the options are inlined into a single multiline regex,
 * so their flags are ignored, `^` and `$` match line boundaries,
 * and they should not contain capturing groups, backreferences or named groups.
 * @param options - Formatter options.
 * @returns Formatter which replaces issue and user references in a text with links.
 */
export declare function createReferencesFormatter<Commit extends CommitKnownProps = CommitKnownProps>(options: ReferencesFormatterOptions<Commit>): ReferencesFormatter<Commit>;
//# sourceMappingURL=references.d.ts.map