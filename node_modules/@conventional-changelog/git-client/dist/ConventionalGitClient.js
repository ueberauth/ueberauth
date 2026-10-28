import { clean as cleanVersion, compareReversed, isValid } from 'verkit';
import { firstFromStream } from '@simple-libs/stream-utils';
import { isPrereleaseVersion } from './utils.js';
import { GitClient } from './GitClient.js';
/**
 * Helper to get package tag prefix.
 * @param packageName
 * @returns Tag prefix.
 */
export function packagePrefix(packageName) {
    if (!packageName) {
        return /^.+@/;
    }
    return `${packageName}@`;
}
/**
 * Wrapper around Git CLI with conventional commits support.
 */
export class ConventionalGitClient extends GitClient {
    deps = null;
    loadDeps() {
        if (this.deps) {
            return this.deps;
        }
        this.deps = Promise.all([
            import('conventional-commits-parser')
                .then(({ parseCommits }) => parseCommits),
            import('conventional-commits-filter')
                .then(({ filterRevertedCommits }) => filterRevertedCommits)
        ]);
        return this.deps;
    }
    /**
     * Get parsed commits stream.
     * @param params
     * @param params.path - Read commits from specific path.
     * @param params.from - Start commits range.
     * @param params.to - End commits range.
     * @param params.format - Commits format.
     * @param parserOptions - Commit parser options.
     * @yields Raw commits data.
     */
    async *getCommits(params = {}, parserOptions = {}) {
        const { filterReverts, ...gitLogParams } = params;
        const [parseCommits, filterRevertedCommits] = await this.loadDeps();
        if (filterReverts) {
            yield* filterRevertedCommits(this.getCommits(gitLogParams, parserOptions));
            return;
        }
        const parse = parseCommits(parserOptions);
        const commitsStream = this.getRawCommits(gitLogParams);
        yield* parse(commitsStream);
    }
    /**
     * Get semver tags stream.
     * @param params
     * @param params.prefix - Get semver tags with specific prefix.
     * @param params.skipUnstable - Skip semver tags with unstable versions.
     * @param params.clean - Clean version from prefix and trash.
     * @param params.path - Read tags from specific path.
     * @param params.from - Start tags range.
     * @param params.to - End tags range.
     * @param params.since - Get tags since specific date.
     * @yields Semver tags.
     */
    async *getSemverTags(params = {}) {
        const { prefix, skipUnstable, clean, ...getTagsParams } = params;
        const tagsStream = this.getTags(getTagsParams);
        const cleanTag = clean
            ? (tag, unprefixed) => cleanVersion(unprefixed || tag)
            : (tag) => tag;
        let unprefixed;
        let tag;
        for await (tag of tagsStream) {
            if (prefix) {
                const isPrefixed = typeof prefix === 'string'
                    ? tag.startsWith(prefix)
                    : prefix.test(tag);
                if (isPrefixed) {
                    unprefixed = tag.replace(prefix, '');
                    if (isValid(unprefixed) && !(skipUnstable && isPrereleaseVersion(unprefixed))) {
                        tag = cleanTag(tag, unprefixed);
                        if (tag) {
                            yield tag;
                        }
                    }
                }
            }
            else if (isValid(tag) && !(skipUnstable && isPrereleaseVersion(tag))) {
                tag = cleanTag(tag);
                if (tag) {
                    yield tag;
                }
            }
        }
    }
    /**
     * Get last semver tag.
     * @param params - getSemverTags params.
     * @returns Last semver tag, `null` if not found.
     */
    async getLastSemverTag(params = {}) {
        return firstFromStream(this.getSemverTags(params));
    }
    /**
     * Get current sematic version from git tags.
     * @param params - Additional git params.
     * @returns Current sematic version, `null` if not found.
     */
    async getVersionFromTags(params = {}) {
        const semverTagsStream = this.getSemverTags({
            clean: true,
            ...params
        });
        const semverTags = [];
        for await (const tag of semverTagsStream) {
            semverTags.push(tag);
        }
        if (!semverTags.length) {
            return null;
        }
        return semverTags.sort(compareReversed)[0] || null;
    }
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiQ29udmVudGlvbmFsR2l0Q2xpZW50LmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsiLi4vc3JjL0NvbnZlbnRpb25hbEdpdENsaWVudC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFNQSxPQUFPLEVBQ0wsS0FBSyxJQUFJLFlBQVksRUFDckIsZUFBZSxFQUNmLE9BQU8sRUFDUixNQUFNLFFBQVEsQ0FBQTtBQUNmLE9BQU8sRUFBRSxlQUFlLEVBQUUsTUFBTSwyQkFBMkIsQ0FBQTtBQUszRCxPQUFPLEVBQUUsbUJBQW1CLEVBQUUsTUFBTSxZQUFZLENBQUE7QUFDaEQsT0FBTyxFQUFFLFNBQVMsRUFBRSxNQUFNLGdCQUFnQixDQUFBO0FBRTFDOzs7O0dBSUc7QUFDSCxNQUFNLFVBQVUsYUFBYSxDQUFDLFdBQW9CO0lBQ2hELElBQUksQ0FBQyxXQUFXLEVBQUUsQ0FBQztRQUNqQixPQUFPLE1BQU0sQ0FBQTtJQUNmLENBQUM7SUFFRCxPQUFPLEdBQUcsV0FBVyxHQUFHLENBQUE7QUFDMUIsQ0FBQztBQUVEOztHQUVHO0FBQ0gsTUFBTSxPQUFPLHFCQUFzQixTQUFRLFNBQVM7SUFDMUMsSUFBSSxHQUF3RSxJQUFJLENBQUE7SUFFaEYsUUFBUTtRQUNkLElBQUksSUFBSSxDQUFDLElBQUksRUFBRSxDQUFDO1lBQ2QsT0FBTyxJQUFJLENBQUMsSUFBSSxDQUFBO1FBQ2xCLENBQUM7UUFFRCxJQUFJLENBQUMsSUFBSSxHQUFHLE9BQU8sQ0FBQyxHQUFHLENBQUM7WUFDdEIsTUFBTSxDQUFDLDZCQUE2QixDQUFDO2lCQUNsQyxJQUFJLENBQUMsQ0FBQyxFQUFFLFlBQVksRUFBRSxFQUFFLEVBQUUsQ0FBQyxZQUFZLENBQUM7WUFDM0MsTUFBTSxDQUFDLDZCQUE2QixDQUFDO2lCQUNsQyxJQUFJLENBQUMsQ0FBQyxFQUFFLHFCQUFxQixFQUFFLEVBQUUsRUFBRSxDQUFDLHFCQUFxQixDQUFDO1NBQzlELENBQUMsQ0FBQTtRQUVGLE9BQU8sSUFBSSxDQUFD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