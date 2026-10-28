import type { FinalTemplateContext, CommitKnownProps, CommitNote, CommitReference, TransformedCommit } from './types/index.js';
/**
 * Builds a repository URL from template context fields.
 * @param context - Template context.
 * @returns Repository URL.
 */
export declare function repositoryUrl<Commit extends CommitKnownProps = CommitKnownProps>(context: FinalTemplateContext<Commit>): string;
/**
 * Builds a repository URL for a commit reference.
 * @param context - Template context.
 * @param reference - Commit reference.
 * @returns Reference repository URL.
 */
export declare function referenceRepositoryUrl<Commit extends CommitKnownProps = CommitKnownProps>(context: FinalTemplateContext<Commit>, reference: CommitReference): string;
/**
 * Builds a release comparison URL and encodes tag names as URL path segments.
 * @param context - Template context.
 * @returns Release comparison URL.
 */
export declare function compareUrl<Commit extends CommitKnownProps = CommitKnownProps>(context: FinalTemplateContext<Commit>): string;
export declare const BREAKING_CHANGE_KEYWORDS: string[];
export declare const BREAKING_CHANGES_TITLE = "BREAKING CHANGES";
/**
 * Renders a note group title.
 * Breaking change keywords are merged into a single title,
 * every other keyword is uppercased to group its spellings together.
 * @param title - Note title as it was written in a commit.
 * @returns Note group title.
 */
export declare function noteTitle(title: string): string;
/**
 * Checks if a note is a breaking change note.
 * @param note - Commit note.
 * @returns Is it a breaking change note.
 */
export declare function isBreakingNote(note: CommitNote): boolean;
/**
 * Renders a commit reference label.
 * @param reference - Commit reference.
 * @returns Commit reference label.
 */
export declare function reference(reference: CommitReference): string;
/**
 * Renders the default changelog header.
 * @param context - Template context.
 * @returns Changelog header.
 */
export declare function headerPartial<Commit extends CommitKnownProps = CommitKnownProps>({ isPatch, title, version, date }: FinalTemplateContext<Commit>): string;
/**
 * Renders the default changelog preamble.
 * @param context - Template context.
 * @returns Changelog preamble.
 */
export declare function preamblePartial<Commit extends CommitKnownProps = CommitKnownProps>({ preamble }: FinalTemplateContext<Commit>): string;
/**
 * Renders the default changelog footer.
 * @param context - Template context.
 * @returns Changelog footer.
 */
export declare function footerPartial<Commit extends CommitKnownProps = CommitKnownProps>({ noteGroups }: FinalTemplateContext<Commit>): string;
/**
 * Renders the default changelog commit line.
 * @param context - Template context.
 * @param commit - Transformed commit.
 * @returns Changelog commit line.
 */
export declare function commitPartial<Commit extends CommitKnownProps = CommitKnownProps>(context: FinalTemplateContext<Commit>, commit: TransformedCommit<Commit>): string;
/**
 * Renders the default changelog template.
 * @param context - Template context.
 * @returns Changelog text.
 */
export declare function template<Commit extends CommitKnownProps = CommitKnownProps>(context: FinalTemplateContext<Commit>): string;
//# sourceMappingURL=templates.d.ts.map