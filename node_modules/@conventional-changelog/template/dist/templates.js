import { each, link, list, small, heading, segments, strings, words, newline, url } from './elements.js';
/**
 * Builds a repository URL from template context fields.
 * @param context - Template context.
 * @returns Repository URL.
 */
export function repositoryUrl(context) {
    if (context.repository) {
        return url(context.host, context.owner, context.repository);
    }
    return context.repoUrl || '';
}
/**
 * Builds a repository URL for a commit reference.
 * @param context - Template context.
 * @param reference - Commit reference.
 * @returns Reference repository URL.
 */
export function referenceRepositoryUrl(context, reference) {
    if (!context.repository) {
        return context.repoUrl || '';
    }
    if (reference.repository) {
        return url(context.host, reference.owner, reference.repository);
    }
    return url(context.host, context.owner, context.repository);
}
/**
 * Builds a release comparison URL and encodes tag names as URL path segments.
 * @param context - Template context.
 * @returns Release comparison URL.
 */
export function compareUrl(context) {
    const previousTag = encodeURIComponent(context.previousTag || '');
    const currentTag = encodeURIComponent(context.currentTag || '');
    return url(repositoryUrl(context), context.compare || 'compare', `${previousTag}...${currentTag}`);
}
export const BREAKING_CHANGE_KEYWORDS = ['BREAKING CHANGE', 'BREAKING-CHANGE'];
export const BREAKING_CHANGES_TITLE = 'BREAKING CHANGES';
/**
 * Renders a note group title.
 * Breaking change keywords are merged into a single title,
 * every other keyword is uppercased to group its spellings together.
 * @param title - Note title as it was written in a commit.
 * @returns Note group title.
 */
export function noteTitle(title) {
    const upperCaseTitle = title.toUpperCase();
    return BREAKING_CHANGE_KEYWORDS.includes(upperCaseTitle)
        ? BREAKING_CHANGES_TITLE
        : upperCaseTitle;
}
/**
 * Checks if a note is a breaking change note.
 * @param note - Commit note.
 * @returns Is it a breaking change note.
 */
export function isBreakingNote(note) {
    return noteTitle(note.title) === BREAKING_CHANGES_TITLE;
}
/**
 * Renders a commit reference label.
 * @param reference - Commit reference.
 * @returns Commit reference label.
 */
export function reference(reference) {
    return strings(reference.owner && `${reference.owner}/`, reference.repository, reference.issue && `${reference.prefix || '#'}${reference.issue}`);
}
/**
 * Renders the default changelog header.
 * @param context - Template context.
 * @returns Changelog header.
 */
export function headerPartial({ isPatch, title, version, date }) {
    const versionText = words(version, title && `"${title}"`, date && `(${date})`);
    return heading(2, isPatch ? small(versionText) : versionText);
}
/**
 * Renders the default changelog preamble.
 * @param context - Template context.
 * @returns Changelog preamble.
 */
export function preamblePartial({ preamble }) {
    return strings(preamble);
}
/**
 * Renders the default changelog footer.
 * @param context - Template context.
 * @returns Changelog footer.
 */
export function footerPartial({ noteGroups }) {
    return each(noteGroups, group => segments(heading(3, group.title), list(group.notes, note => note.text)), newline(2));
}
/**
 * Renders the default changelog commit line.
 * @param context - Template context.
 * @param commit - Transformed commit.
 * @returns Changelog commit line.
 */
export function commitPartial(context, commit) {
    const { linkReferences, issue, commit: commitUrlPath } = context;
    const { hash, references, header } = commit;
    const commitLink = hash
        ? linkReferences
            ? `(${link(hash, url(repositoryUrl(context), commitUrlPath, hash))})`
            : hash
        : '';
    const renderedReferences = each(references, (linkReference) => {
        if (linkReferences) {
            return link(reference(linkReference), url(referenceRepositoryUrl(context, linkReference), issue, linkReference.issue));
        }
        return reference(linkReference);
    }, ' ');
    return strings(words(header, commitLink), renderedReferences && `, closes ${renderedReferences}`);
}
/**
 * Renders the default changelog template.
 * @param context - Template context.
 * @returns Changelog text.
 */
export function template(context) {
    const { headerPartial, preamblePartial, commitPartial, footerPartial, commitGroups } = context;
    return segments(headerPartial(context), preamblePartial(context), each(commitGroups, group => list(group.commits, commit => commitPartial(context, commit))), footerPartial(context));
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidGVtcGxhdGVzLmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsiLi4vc3JjL3RlbXBsYXRlcy50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFPQSxPQUFPLEVBQ0wsSUFBSSxFQUNKLElBQUksRUFDSixJQUFJLEVBQ0osS0FBSyxFQUNMLE9BQU8sRUFDUCxRQUFRLEVBQ1IsT0FBTyxFQUNQLEtBQUssRUFDTCxPQUFPLEVBQ1AsR0FBRyxFQUNKLE1BQU0sZUFBZSxDQUFBO0FBRXRCOzs7O0dBSUc7QUFDSCxNQUFNLFVBQVUsYUFBYSxDQUMzQixPQUFxQztJQUVyQyxJQUFJLE9BQU8sQ0FBQyxVQUFVLEVBQUUsQ0FBQztRQUN2QixPQUFPLEdBQUcsQ0FBQyxPQUFPLENBQUMsSUFBSSxFQUFFLE9BQU8sQ0FBQyxLQUFLLEVBQUUsT0FBTyxDQUFDLFVBQVUsQ0FBQyxDQUFBO0lBQzdELENBQUM7SUFFRCxPQUFPLE9BQU8sQ0FBQyxPQUFPLElBQUksRUFBRSxDQUFBO0FBQzlCLENBQUM7QUFFRDs7Ozs7R0FLRztBQUNILE1BQU0sVUFBVSxzQkFBc0IsQ0FDcEMsT0FBcUMsRUFDckMsU0FBMEI7SUFFMUIsSUFBSSxDQUFDLE9BQU8sQ0FBQyxVQUFVLEVBQUUsQ0FBQztRQUN4QixPQUFPLE9BQU8sQ0FBQyxPQUFPLElBQUksRUFBRSxDQUFBO0lBQzlCLENBQUM7SUFFRCxJQUFJLFNBQVMsQ0FBQyxVQUFVLEVBQUUsQ0FBQztRQUN6QixPQUFPLEdBQUcsQ0FBQyxPQUFPLENBQUMsSUFBSSxFQUFFLFNBQVMsQ0FBQyxLQUFLLEVBQUUsU0FBUyxDQUFDLFVBQVUsQ0FBQyxDQUFBO0lBQ2pFLENBQUM7SUFFRCxPQUFPLEdBQUcsQ0FBQyxPQUFPLENBQUMsSUFBSSxFQUFFLE9BQU8sQ0FBQyxLQUFLLEVBQUUsT0FBTyxDQUFDLFVBQVUsQ0FBQyxDQUFBO0FBQzdELENBQUM7QUFFRDs7OztHQUlHO0FBQ0gsTUFBTSxVQUFVLFVBQVUsQ0FDeEIsT0FBcUM7SUFFckMs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