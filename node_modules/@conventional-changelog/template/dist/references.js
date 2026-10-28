import { link } from './elements.js';
/**
 * Markdown segments to keep as is: replacing references inside them
 * would break already formatted links, code samples and urls.
 */
const protectedSegments = [
    /\[(?:[^[\]]|\[[^[\]]*])*]\((?:[^()\n]|\([^()\n]*\))*\)/, // [text](url)
    /\[[^\]]*]\[[^\]]*]/, // [text][ref]
    // the lookahead makes the delimiter length atomic, without it a long run
    // of backticks makes the regex engine retry every possible delimiter length
    /^[ \t]*(?=(?<fence>`{3,}|~{3,}))\k<fence>[\s\S]*?^[ \t]*\k<fence>[ \t]*\r?$/, // ```code block```
    /(?=(?<code>`+))\k<code>[^\n]*?\k<code>/, // `code span`
    /https?:\/\/(?:[^\s()]|\([^\s()]*\))+/ // https://url
];
const userMention = /\B@(?<user>[a-z0-9](?:-?[a-z0-9/]){0,38})/;
const defaultIssuePattern = /[a-z0-9]+/;
/**
 * Escapes a string to use it as a part of a regex.
 * @param string
 * @returns Escaped string.
 */
function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
/**
 * Builds a regex which matches issue and user references
 * outside of the protected Markdown segments.
 * @param issuePrefixes
 * @param issuePattern
 * @returns Regex with `prefix`, `issue` and `user` groups.
 */
function referencesRegex(issuePrefixes = [], issuePattern = defaultIssuePattern) {
    const prefixes = issuePrefixes
        .map(prefix => (typeof prefix === 'string' ? escapeRegExp(prefix) : prefix.source))
        .join('|');
    const patterns = [
        ...protectedSegments.map(segment => segment.source),
        // without prefixes every word would be matched as an issue reference
        prefixes && `(?<prefix>${prefixes})(?<issue>${issuePattern.source})`,
        userMention.source
    ];
    return new RegExp(patterns.filter(Boolean).join('|'), 'gm');
}
/**
 * Creates a text formatter for the given options.
 *
 * Regexes from the options are inlined into a single multiline regex,
 * so their flags are ignored, `^` and `$` match line boundaries,
 * and they should not contain capturing groups, backreferences or named groups.
 * @param options - Formatter options.
 * @returns Formatter which replaces issue and user references in a text with links.
 */
export function createReferencesFormatter(options) {
    const regex = referencesRegex(options.issuePrefixes, options.issuePattern);
    return (text, context, references) => text.replace(regex, (match, ...args) => {
        const { prefix, issue, user } = args.at(-1);
        if (issue) {
            const issueUrl = options.formatIssueUrl(context, {
                prefix: prefix,
                issue
            });
            if (!issueUrl) {
                return match;
            }
            references?.push(match);
            return link(match, issueUrl);
        }
        if (user) {
            // TODO: investigate why this code exists.
            if (user.includes('/')) {
                return match;
            }
            const userUrl = options.formatUserUrl(context, user);
            if (!userUrl) {
                return match;
            }
            return link(match, userUrl);
        }
        return match;
    });
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoicmVmZXJlbmNlcy5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIi4uL3NyYy9yZWZlcmVuY2VzLnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiJBQUlBLE9BQU8sRUFBRSxJQUFJLEVBQUUsTUFBTSxlQUFlLENBQUE7QUFFcEM7OztHQUdHO0FBQ0gsTUFBTSxpQkFBaUIsR0FBRztJQUN4Qix3REFBd0QsRUFBRSxjQUFjO0lBQ3hFLG9CQUFvQixFQUFFLGNBQWM7SUFDcEMseUVBQXlFO0lBQ3pFLDRFQUE0RTtJQUM1RSw2RUFBNkUsRUFBRSxtQkFBbUI7SUFDbEcsd0NBQXdDLEVBQUUsY0FBYztJQUN4RCxzQ0FBc0MsQ0FBQyxjQUFjO0NBQ3RELENBQUE7QUFDRCxNQUFNLFdBQVcsR0FBRywyQ0FBMkMsQ0FBQTtBQUMvRCxNQUFNLG1CQUFtQixHQUFHLFdBQVcsQ0FBQTtBQXdDdkM7Ozs7R0FJRztBQUNILFNBQVMsWUFBWSxDQUFDLE1BQWM7SUFDbEMsT0FBTyxNQUFNLENBQUMsT0FBTyxDQUFDLHFCQUFxQixFQUFFLE1BQU0sQ0FBQyxDQUFBO0FBQ3RELENBQUM7QUFFRDs7Ozs7O0dBTUc7QUFDSCxTQUFTLGVBQWUsQ0FDdEIsYUFBYSxHQUF3QixFQUFFLEVBQ3ZDLFlBQVksR0FBVyxtQkFBbUI7SUFFMUMsTUFBTSxRQUFRLEdBQUcsYUFBYTtTQUMzQixHQUFHLENBQUMsTUFBTSxDQUFDLEVBQUUsQ0FBQyxDQUFDLE9BQU8sTUFBTSxLQUFLLFFBQVEsQ0FBQyxDQUFDLENBQUMsWUFBWSxDQUFDLE1BQU0sQ0FBQyxDQUFDLENBQUMsQ0FBQyxNQUFNLENBQUMsTUFBTSxDQUFDLENBQUM7U0FDbEYsSUFBSSxDQUFDLEdBQUcsQ0FBQyxDQUFBO0lBQ1osTUFBTSxRQUFRLEdBQUc7UUFDZixHQUFHLGlCQUFpQixDQUFDLEdBQUcsQ0FBQyxPQUFPLENBQUMsRUFBRSxDQUFDLE9BQU8sQ0FBQyxNQUFNLENBQUM7UUFDbkQscUVBQXFFO1FBQ3JFLFFBQVEsSUFBSSxhQUFhLFFBQVEsYUFBYSxZQUFZLENBQUMsTUFBTSxHQUFHO1FBQ3BFLFdBQVcsQ0FBQyxNQUFNO0tBQ25CLENBQUE7SUFFRCxPQUFPLElBQUksTUFBTSxDQUFDLFFBQVEsQ0FBQyxNQUFNLENBQUMsT0FBTyxDQUFDLENBQUMsSUFBSSxDQUFDLEdBQUcsQ0FBQyxFQUFFLElBQUksQ0FBQyxDQUFBO0FBQzdELENBQUM7QUFFRDs7Ozs7Ozs7R0FRRztBQUNILE1BQU0sVUFBVSx5QkFBeUIsQ0FDdkMsT0FBMkM7SUFFM0MsTUFBTSxLQUFLLEdBQUcsZUFBZSxDQUFDLE9BQU8sQ0FBQyxhQUFhLEVBQUUsT0FBTyxDQUFDLFlBQVksQ0FBQyxDQUFBO0lBRTFFLE9BQU8sQ0FBQyxJQUFJLEVBQUUsT0FBTyxFQUFFLFVBQVUsRUFBRSxFQUFFLENBQUMsSUFBSSxDQUFDLE9BQU8sQ0FBQyxLQUFLLEVBQUUsQ0FBQyxLQUFLLEVBQUUsR0FBRyxJQUFJLEVBQUUsRUFBRTtRQUMzRSxNQUFNLEVBQ0osTUFBTSxFQUNOLEtBQUssRUFDTCxJQUFJLEVBQ0wsR0FBRyxJQUFJLENBQUMsRUFBRSxDQUFDLENBQUMsQ0FBQyxDQUErQyxDQUFBO1FBRTdELElBQUksS0FBSyxFQUFFLENBQUM7WUFDVixNQUFNLFFBQVEsR0FBRyxPQUFPLENBQUMsY0FBYyxDQUFDLE9BQU8sRUFBRTtnQkFDL0MsTUFBTSxFQUFFLE1BQWdCO2dCQUN4QixLQUFLO2FBQ04sQ0FBQyxDQUFBO1lBRUYsSUFBSSxDQUFDLFFBQVEsRUFBRSxDQUFDO2dCQUNkLE9BQU8sS0FBSyxDQUFBO1lBQ2QsQ0FBQztZQUVELFVBQVUsRUFBRSxJQUFJLENBQUMsS0FBSyxDQUFDLENBQUE7WUFFdkIsT0FBTyxJQUFJLENBQUMsS0FBSyxFQUFFLFFBQVEsQ0FBQyxDQUFBO1FBQzlCLENBQUM7UUFFRCxJQUFJLElBQUksRUFBRSxDQUFDO1lBQ1QsMENBQTBDO1lBQzFDLElBQUksSUFBSSxDQUFDLFFBQVEsQ0FBQyxHQUFHLENBQUMsRUFBRSxDQUFDO2dCQUN2QixPQUFPLEtBQUssQ0FBQTtZQUNkLENBQUM7WUFFRCxNQUFNLE9BQU8sR0FBRyxPQUFPLENBQUMsYUFBYSxDQUFDLE9BQU8sRUFBRSxJQUFJLENBQUMsQ0FBQTtZQUVwRCxJQUFJLENBQUMsT0FBTyxFQUFFLENBQUM7Z0JBQ2IsT0FBTyxLQUFLLENBQUE7WUFDZCxDQUFDO1lBRUQsT0FBTyxJQUFJLENBQUMsS0FBSyxFQUFFLE9BQU8sQ0FBQyxDQUFBO1FBQzdCLENBQUM7UUFFRCxPQUFPLEtBQUssQ0FBQTtJQUNkLENBQUMsQ0FBQyxDQUFBO0FBQ0osQ0FBQyJ9