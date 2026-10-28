import { Transform } from 'stream';
import { CommitParser } from './CommitParser.js';
/**
 * Create async generator function to parse async iterable of raw commits.
 * @param options - CommitParser options.
 * @returns Async generator function to parse async iterable of raw commits.
 */
export function parseCommits(options = {}) {
    const warnOption = options.warn;
    const warn = warnOption === true
        ? (err) => {
            throw err;
        }
        : warnOption
            ? (err) => warnOption(err.toString())
            : () => { };
    return async function* parse(rawCommits) {
        const parser = new CommitParser(options);
        let rawCommit;
        for await (rawCommit of rawCommits) {
            try {
                yield parser.parse(rawCommit.toString());
            }
            catch (err) {
                warn(err);
            }
        }
    };
}
/**
 * Create stream to parse commits.
 * @param options - CommitParser options.
 * @returns Stream of parsed commits.
 */
export function parseCommitsStream(options = {}) {
    return Transform.from(parseCommits(options));
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoic3RyZWFtLmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsiLi4vc3JjL3N0cmVhbS50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFBQSxPQUFPLEVBQUUsU0FBUyxFQUFFLE1BQU0sUUFBUSxDQUFBO0FBRWxDLE9BQU8sRUFBRSxZQUFZLEVBQUUsTUFBTSxtQkFBbUIsQ0FBQTtBQUVoRDs7OztHQUlHO0FBQ0gsTUFBTSxVQUFVLFlBQVksQ0FDMUIsT0FBTyxHQUF3QixFQUFFO0lBRWpDLE1BQU0sVUFBVSxHQUFHLE9BQU8sQ0FBQyxJQUFJLENBQUE7SUFDL0IsTUFBTSxJQUFJLEdBQUcsVUFBVSxLQUFLLElBQUk7UUFDOUIsQ0FBQyxDQUFDLENBQUMsR0FBVSxFQUFFLEVBQUU7WUFDZixNQUFNLEdBQUcsQ0FBQTtRQUNYLENBQUM7UUFDRCxDQUFDLENBQUMsVUFBVTtZQUNWLENBQUMsQ0FBQyxDQUFDLEdBQVUsRUFBRSxFQUFFLENBQUMsVUFBVSxDQUFDLEdBQUcsQ0FBQyxRQUFRLEVBQUUsQ0FBQztZQUM1QyxDQUFDLENBQUMsR0FBRyxFQUFFLEdBQWMsQ0FBQyxDQUFBO0lBRTFCLE9BQU8sS0FBSyxTQUFTLENBQUMsQ0FBQyxLQUFLLENBQzFCLFVBQXNFO1FBRXRFLE1BQU0sTUFBTSxHQUFHLElBQUksWUFBWSxDQUFDLE9BQU8sQ0FBQyxDQUFBO1FBQ3hDLElBQUksU0FBMEIsQ0FBQTtRQUU5QixJQUFJLEtBQUssRUFBRSxTQUFTLElBQUksVUFBVSxFQUFFLENBQUM7WUFDbkMsSUFBSSxDQUFDO2dCQUNILE1BQU0sTUFBTSxDQUFDLEtBQUssQ0FBQyxTQUFTLENBQUMsUUFBUSxFQUFFLENBQUMsQ0FBQTtZQUMxQyxDQUFDO1lBQUMsT0FBTyxHQUFHLEVBQUUsQ0FBQztnQkFDYixJQUFJLENBQUMsR0FBWSxDQUFDLENBQUE7WUFDcEIsQ0FBQztRQUNILENBQUM7SUFDSCxDQUFDLENBQUE7QUFDSCxDQUFDO0FBRUQ7Ozs7R0FJRztBQUNILE1BQU0sVUFBVSxrQkFBa0IsQ0FBQyxPQUFPLEdBQXdCLEVBQUU7SUFDbEUsT0FBTyxTQUFTLENBQUMsSUFBSSxDQUFDLFlBQVksQ0FBQyxPQUFPLENBQUMsQ0FBQyxDQUFBO0FBQzlDLENBQUMifQ==