const nomatchRegex = /(?!.*)/;
function escape(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
function joinOr(parts) {
    return parts
        .map(val => (typeof val === 'string' ? escape(val.trim()) : val.source))
        .filter(Boolean)
        .join('|');
}
function getNotesRegex(noteKeywords, notesPattern) {
    if (!noteKeywords) {
        return nomatchRegex;
    }
    const noteKeywordsSelection = joinOr(noteKeywords);
    if (!notesPattern) {
        return new RegExp(`^(?:\\*\\s+)?(${noteKeywordsSelection}):\\s*(.*)`, 'i');
    }
    return notesPattern(noteKeywordsSelection);
}
function getReferencePartsRegex(issuePrefixes, issuePrefixesCaseSensitive) {
    if (!issuePrefixes) {
        return nomatchRegex;
    }
    const flags = issuePrefixesCaseSensitive ? 'g' : 'gi';
    return new RegExp(`(?:.*?)??\\s*([\\w-\\.\\/]*?)??(${joinOr(issuePrefixes)})([\\w-]+)(?=\\s|$|[,;.)\\]])`, flags);
}
function getReferencesRegex(referenceActions, separator = '') {
    if (!referenceActions) {
        // matches everything
        return /()(.+)/gi;
    }
    const joinedKeywords = joinOr(referenceActions);
    // Keywords are whole words: `prefix #1` has no `fix` action,
    // and `fixups` does not end the references of the previous keyword.
    const nextKeyword = `(?<!\\w)(?:${joinedKeywords})(?!\\w)`;
    return new RegExp(`(?<!\\w)(${joinedKeywords})${separator}(?:\\s+(.*?))(?=${nextKeyword}|$)`, 'gi');
}
function getFooterTokenRegex(issuePrefixes) {
    const issuePrefixSeparator = issuePrefixes
        ? `|\\s+(?:${joinOr(issuePrefixes)})`
        : '';
    // Footers follow the git trailer convention: the token starts at the
    // beginning of the line, indented `key: value` lines are not footers.
    return new RegExp(`^(?:BREAKING CHANGE|[\\w-]+)(?::\\s+${issuePrefixSeparator}).+`, 'i');
}
/**
 * Make the regexes used to parse a commit.
 * @param options
 * @returns Regexes.
 */
export function getParserRegexes(options = {}) {
    const notes = getNotesRegex(options.noteKeywords, options.notesPattern);
    const referenceParts = getReferencePartsRegex(options.issuePrefixes, options.issuePrefixesCaseSensitive);
    const references = getReferencesRegex(options.referenceActions);
    // In a footer the keyword is a token, which may be followed by a colon: `Closes: #1`
    const footerReferences = getReferencesRegex(options.referenceActions, ':?');
    const footerToken = getFooterTokenRegex(options.issuePrefixes);
    return {
        notes,
        referenceParts,
        references,
        footerReferences,
        footerToken,
        mentions: /@([\w-]+)/g,
        url: /\b(?:https?):\/\/(?:www\.)?([-a-zA-Z0-9@:%_+.~#?&//=])+\b/
    };
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoicmVnZXguanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi9zcmMvcmVnZXgudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBS0EsTUFBTSxZQUFZLEdBQUcsUUFBUSxDQUFBO0FBRTdCLFNBQVMsTUFBTSxDQUFDLE1BQWM7SUFDNUIsT0FBTyxNQUFNLENBQUMsT0FBTyxDQUFDLHFCQUFxQixFQUFFLE1BQU0sQ0FBQyxDQUFBO0FBQ3RELENBQUM7QUFFRCxTQUFTLE1BQU0sQ0FBQyxLQUEwQjtJQUN4QyxPQUFPLEtBQUs7U0FDVCxHQUFHLENBQUMsR0FBRyxDQUFDLEVBQUUsQ0FBQyxDQUFDLE9BQU8sR0FBRyxLQUFLLFFBQVEsQ0FBQyxDQUFDLENBQUMsTUFBTSxDQUFDLEdBQUcsQ0FBQyxJQUFJLEVBQUUsQ0FBQyxDQUFDLENBQUMsQ0FBQyxHQUFHLENBQUMsTUFBTSxDQUFDLENBQUM7U0FDdkUsTUFBTSxDQUFDLE9BQU8sQ0FBQztTQUNmLElBQUksQ0FBQyxHQUFHLENBQUMsQ0FBQTtBQUNkLENBQUM7QUFFRCxTQUFTLGFBQWEsQ0FDcEIsWUFBNkMsRUFDN0MsWUFBb0Q7SUFFcEQsSUFBSSxDQUFDLFlBQVksRUFBRSxDQUFDO1FBQ2xCLE9BQU8sWUFBWSxDQUFBO0lBQ3JCLENBQUM7SUFFRCxNQUFNLHFCQUFxQixHQUFHLE1BQU0sQ0FBQyxZQUFZLENBQUMsQ0FBQTtJQUVsRCxJQUFJLENBQUMsWUFBWSxFQUFFLENBQUM7UUFDbEIsT0FBTyxJQUFJLE1BQU0sQ0FBQyxpQkFBaUIscUJBQXFCLFlBQVksRUFBRSxHQUFHLENBQUMsQ0FBQTtJQUM1RSxDQUFDO0lBRUQsT0FBTyxZQUFZLENBQUMscUJBQXFCLENBQUMsQ0FBQTtBQUM1QyxDQUFDO0FBRUQsU0FBUyxzQkFBc0IsQ0FDN0IsYUFBOEMsRUFDOUMsMEJBQStDO0lBRS9DLElBQUksQ0FBQyxhQUFhLEVBQUUsQ0FBQztRQUNuQixPQUFPLFlBQVksQ0FBQTtJQUNyQixDQUFDO0lBRUQsTUFBTSxLQUFLLEdBQUcsMEJBQTBCLENBQUMsQ0FBQyxDQUFDLEdBQUcsQ0FBQyxDQUFDLENBQUMsSUFBSSxDQUFBO0lBRXJELE9BQU8sSUFBSSxNQUFNLENBQUMsbUNBQW1DLE1BQU0sQ0FBQyxhQUFhLENBQUMsK0JBQStCLEVBQUUsS0FBSyxDQUFDLENBQUE7QUFDbkgsQ0FBQztBQUVELFNBQVMsa0JBQWtCLENBQ3pCLGdCQUFpRCxFQUNqRCxTQUFTLEdBQUcsRUFBRTtJQUVkLElBQUksQ0FBQyxnQkFBZ0IsRUFBRSxDQUFDO1FBQ3RCLHFCQUFxQjtRQUNyQixPQUFPLFVBQVUsQ0FBQTtJQUNuQixDQUFDO0lBRUQsTUFBTSxjQUFjLEdBQUcsTUFBTSxDQUFDLGdCQUFnQixDQUFDLENBQUE7SUFDL0MsNkRBQTZEO0lBQzdELG9FQUFvRTtJQUNwRSxNQUFNLFdBQVcsR0FBRyxjQUFjLGNBQWMsVUFBVSxDQUFBO0lBRTFELE9BQU8sSUFBSSxNQUFNLENBQUMsWUFBWSxjQUFjLElBQUksU0FBUyxtQkFBbUIsV0FBVyxLQUFLLEVBQUUsSUFBSSxDQUFDLENBQUE7QUFDckcsQ0FBQztBQUVELFNBQVMsbUJBQW1CLENBQzFCLGFBQThDO0lBRTlDLE1BQU0sb0JBQW9CLEdBQUcsYUFBYTtRQUN4QyxDQUFDLENBQUMsV0FBVyxNQUFNLENBQUMsYUFBYSxDQUFDLEdBQUc7UUFDckMsQ0FBQyxDQUFDLEVBQUUsQ0FBQTtJQUVOLHFFQUFxRTtJQUNyRSxzRUFBc0U7SUFDdEUsT0FBTyxJQUFJLE1BQU0sQ0FBQyx1Q0FBdUMsb0JBQW9CLEtBQUssRUFBRSxHQUFHLENBQUMsQ0FBQTtBQUMxRixDQUFDO0FBRUQ7Ozs7R0FJRztBQUNILE1BQU0sVUFBVSxnQkFBZ0IsQ0FDOUIsT0FBTyxHQUErSCxFQUFFO0lBRXhJLE1BQU0sS0FBSyxHQUFHLGFBQWEsQ0FBQyxPQUFPLENBQUMsWUFBWSxFQUFFLE9BQU8sQ0FBQyxZQUFZLENBQUMsQ0FBQTtJQUN2RSxNQUFNLGNBQWMsR0FBRyxzQkFBc0IsQ0FBQyxPQUFPLENBQUMsYUFBYSxFQUFFLE9BQU8sQ0FBQywwQkFBMEIsQ0FBQyxDQUFBO0lBQ3hHLE1BQU0sVUFBVSxHQUFHLGtCQUFrQixDQUFDLE9BQU8sQ0FBQyxnQkFBZ0IsQ0FBQyxDQUFBO0lBQy9ELHFGQUFxRjtJQUNyRixNQUFNLGdCQUFnQixHQUFHLGtCQUFrQixDQUFDLE9BQU8sQ0FBQyxnQkFBZ0IsRUFBRSxJQUFJLENBQUMsQ0FBQTtJQUMzRSxNQUFNLFdBQVcsR0FBRyxtQkFBbUIsQ0FBQyxPQUFPLENBQUMsYUFBYSxDQUFDLENBQUE7SUFFOUQsT0FBTztRQUNMLEtBQUs7UUFDTCxjQUFjO1FBQ2QsVUFBVTtRQUNWLGdCQUFnQjtRQUNoQixXQUFXO1FBQ1gsUUFBUSxFQUFFLFlBQVk7UUFDdEIsR0FBRyxFQUFFLDJEQUEyRDtLQUNqRSxDQUFBO0FBQ0gsQ0FBQyJ9