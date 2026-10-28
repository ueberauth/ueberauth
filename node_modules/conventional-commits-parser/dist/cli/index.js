#!/usr/bin/env node
import { pipeline } from 'stream/promises';
import { readFile } from 'fs/promises';
import { readOptions, option, flag, alias, autocase, rest } from 'argue-cli';
import { parseCommits } from '../index.js';
import { parseOptions } from './options.js';
import { readRawCommitsFromFiles, readRawCommitsFromLine, readRawCommitsFromStdin, stringify } from './utils.js';
const DEFAULT_SEPARATOR = '\n\n\n';
const HELP = `
  Practice writing commit messages or parse messages from files.
  If used without specifying a text file path, you will enter an interactive shell.
  Otherwise the commit messages in the files are parsed and printed
  By default, commits will be split by three newlines ('\\n\\n\\n') or you can specify a separator.

  Usage
    conventional-commits-parser [-s <commit-separator>]
    conventional-commits-parser [-s <commit-separator>] <path> [<path> ...]
    cat <path> | conventional-commits-parser [-s <commit-separator>]

  Example
    conventional-commits-parser
    conventional-commits-parser log.txt
    cat log.txt | conventional-commits-parser
    conventional-commits-parser log2.txt -s '===' >> parsed.txt

  Options
    -s, --separator                   Commit separator
    -p, --header-pattern              Regex to match header pattern
    -c, --header-correspondence       Comma separated parts used to define what capturing group of 'headerPattern' captures what
    -r, --reference-actions           Comma separated keywords that used to reference issues
    -i, --issue-prefixes              Comma separated prefixes of an issue
    --issue-prefixes-case-sensitive   Treat issue prefixes as case sensitive
    -n, --note-keywords               Comma separated keywords for important notes
    -f, --field-pattern               Regex to match other fields
    --revert-pattern                  Regex to match revert pattern
    --revert-correspondence           Comma separated fields used to define what the commit reverts
    -v, --verbose                     Verbose output
`;
const flags = readOptions(option(alias('separator', 's'), String), option(autocase(alias('headerPattern', 'p')), String), option(autocase(alias('headerCorrespondence', 'c')), String), option(autocase(alias('referenceActions', 'r')), String), option(autocase(alias('issuePrefixes', 'i')), String), flag(autocase('issuePrefixesCaseSensitive')), option(autocase(alias('noteKeywords', 'n')), String), option(autocase(alias('fieldPattern', 'f')), String), option(autocase('revertPattern'), String), option(autocase('revertCorrespondence'), String), flag(alias('verbose', 'v')), flag('help'), flag('version'));
const files = rest();
if (flags.help || flags.version) {
    const pkg = JSON.parse(await readFile(new URL('../../package.json', import.meta.url), 'utf8'));
    console.log(flags.help
        ? `\n  ${pkg.description}\n${HELP}`
        : pkg.version);
    process.exit(0);
}
const separator = flags.separator ?? DEFAULT_SEPARATOR;
const options = parseOptions(flags);
let inputStream;
try {
    if (files.length) {
        inputStream = readRawCommitsFromFiles(files, separator);
    }
    else if (process.stdin.isTTY) {
        inputStream = readRawCommitsFromLine(separator);
    }
    else {
        inputStream = readRawCommitsFromStdin(separator);
    }
    await pipeline(inputStream, parseCommits(options), stringify, process.stdout);
}
catch (err) {
    console.error(err);
    process.exit(1);
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiaW5kZXguanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi8uLi9zcmMvY2xpL2luZGV4LnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiI7QUFDQSxPQUFPLEVBQUUsUUFBUSxFQUFFLE1BQU0saUJBQWlCLENBQUE7QUFDMUMsT0FBTyxFQUFFLFFBQVEsRUFBRSxNQUFNLGFBQWEsQ0FBQTtBQUN0QyxPQUFPLEVBQ0wsV0FBVyxFQUNYLE1BQU0sRUFDTixJQUFJLEVBQ0osS0FBSyxFQUNMLFFBQVEsRUFDUixJQUFJLEVBQ0wsTUFBTSxXQUFXLENBQUE7QUFDbEIsT0FBTyxFQUFFLFlBQVksRUFBRSxNQUFNLGFBQWEsQ0FBQTtBQUMxQyxPQUFPLEVBQUUsWUFBWSxFQUFFLE1BQU0sY0FBYyxDQUFBO0FBQzNDLE9BQU8sRUFDTCx1QkFBdUIsRUFDdkIsc0JBQXNCLEVBQ3RCLHVCQUF1QixFQUN2QixTQUFTLEVBQ1YsTUFBTSxZQUFZLENBQUE7QUFFbkIsTUFBTSxpQkFBaUIsR0FBRyxRQUFRLENBQUE7QUFDbEMsTUFBTSxJQUFJLEdBQUc7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0NBNkJaLENBQUE7QUFDRCxNQUFNLEtBQUssR0FBRyxXQUFXLENBQ3ZCLE1BQU0sQ0FBQyxLQUFLLENBQUMsV0FBVyxFQUFFLEdBQUcsQ0FBQyxFQUFFLE1BQU0sQ0FBQyxFQUN2QyxNQUFNLENBQUMsUUFBUSxDQUFDLEtBQUssQ0FBQyxlQUFlLEVBQUUsR0FBRyxDQUFDLENBQUMsRUFBRSxNQUFNLENBQUMsRUFDckQsTUFBTSxDQUFDLFFBQVEsQ0FBQyxLQUFLLENBQUMsc0JBQXNCLEVBQUUsR0FBRyxDQUFDLENBQUMsRUFBRSxNQUFNLENBQUMsRUFDNUQsTUFBTSxDQUFDLFFBQVEsQ0FBQyxLQUFLLENBQUMsa0JBQWtCLEVBQUUsR0FBRyxDQUFDLENBQUMsRUFBRSxNQUFNLENBQUMsRUFDeEQsTUFBTSxDQUFDLFFBQVEsQ0FBQyxLQUFLLENBQUMsZUFBZSxFQUFFLEdBQUcsQ0FBQyxDQUFDLEVBQUUsTUFBTSxDQUFDLEVBQ3JELElBQUksQ0FBQyxRQUFRLENBQUMsNEJBQTRCLENBQUMsQ0FBQyxFQUM1QyxNQUFNLENBQUMsUUFBUSxDQUFDLEtBQUssQ0FBQyxjQUFjLEVBQUUsR0FBRyxDQUFDLENBQUMsRUFBRSxNQUFNLENBQUMsRUFDcEQsTUFBTSxDQUFDLFFBQVEsQ0FBQyxLQUFLLENBQUMsY0FBYyxFQUFFLEdBQUcsQ0FBQyxDQUFDLEVBQUUsTUFBTSxDQUFDLEVBQ3BELE1BQU0sQ0FBQyxRQUFRLENBQUMsZUFBZSxDQUFDLEVBQUUsTUFBTSxDQUFDLEVBQ3pDLE1BQU0sQ0FBQyxRQUFRLENBQUMsc0JBQXNCLENBQUMsRUFBRSxNQUFNLENBQUMsRUFDaEQsSUFBSSxDQUFDLEtBQUssQ0FBQyxTQUFTLEVBQUUsR0FBRyxDQUFDLENBQUMsRUFDM0IsSUFBSSxDQUFDLE1BQU0sQ0FBQyxFQUNaLElBQUksQ0FBQyxTQUFTLENBQUMsQ0FDaEIsQ0FBQTtBQUNELE1BQU0sS0FBSyxHQUFHLElBQUksRUFBRSxDQUFBO0FBRXBCLElBQUksS0FBSyxDQUFDLElBQUksSUFBSSxLQUFLLENBQUMsT0FBTyxFQUFFLENBQUM7SUFDaEMsTUFBTSxHQUFHLEdBQUcsSUFBSSxDQUFDLEtBQUssQ0FDcEIsTUFBTSxRQUFRLENBQUMsSUFBSSxHQUFHLENBQUMsb0JBQW9CLEVBQUUsT0FBTyxJQUFJLENBQUMsR0FBRyxDQUFDLEVBQUUsTUFBTSxDQUFDLENBSXZFLENBQUE7SUFFRCxPQUFPLENBQUMsR0FBRyxDQUNULEtBQUssQ0FBQyxJQUFJO1FBQ1IsQ0FBQyxDQUFDLE9BQU8sR0FBRyxDQUFDLFdBQVcsS0FBSyxJQUFJLEVBQUU7UUFDbkMsQ0FBQyxDQUFDLEdBQUcsQ0FBQyxPQUFPLENBQ2hCLENBQUE7SUFDRCxPQUFPLENBQUMsSUFBSSxDQUFDLENBQUMsQ0FBQyxDQUFBO0FBQ2pCLENBQUM7QUFFRCxNQUFNLFNBQVMsR0FBRyxLQUFLLENBQUMsU0FBUyxJQUFJLGlCQUFpQixDQUFBO0FBQ3RELE1BQU0sT0FBTyxHQUFHLFlBQVksQ0FBQyxLQUFLLENBQUMsQ0FBQTtBQUNuQyxJQUFJLFdBQWtDLENBQUE7QUFFdEMsSUFBSSxDQUFDO0lBQ0gsSUFBSSxLQUFLLENBQUMsTUFBTSxFQUFFLENBQUM7UUFDakIsV0FBVyxHQUFHLHVCQUF1QixDQUFDLEtBQUssRUFBRSxTQUFTLENBQUMsQ0FBQTtJQUN6RCxDQUFDO1NBQ0MsSUFBSSxPQUFPLENBQUMsS0FBSyxDQUFDLEtBQUssRUFBRSxDQUFDO1FBQ3hCLFdBQVcsR0FBRyxzQkFBc0IsQ0FBQyxTQUFTLENBQUMsQ0FBQTtJQUNqRCxDQUFDO1NBQU0sQ0FBQztRQUNOLFdBQVcsR0FBRyx1QkFBdUIsQ0FBQyxTQUFTLENBQUMsQ0FBQTtJQUNsRCxDQUFDO0lBRUgsTUFBTSxRQUFRLENBQ1osV0FBVyxFQUNYLFlBQVksQ0FBQyxPQUFPLENBQUMsRUFDckIsU0FBUyxFQUNULE9BQU8sQ0FBQyxNQUFNLENBQ2YsQ0FBQTtBQUNILENBQUM7QUFBQyxPQUFPLEdBQUcsRUFBRSxDQUFDO0lBQ2IsT0FBTyxDQUFDLEtBQUssQ0FBQyxHQUFHLENBQUMsQ0FBQTtJQUNsQixPQUFPLENBQUMsSUFBSSxDQUFDLENBQUMsQ0FBQyxDQUFBO0FBQ2pCLENBQUMifQ==