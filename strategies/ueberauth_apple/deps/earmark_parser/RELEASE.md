
## 1.5.0 2023-??-??

-  [Depreacting message to be passed in as an array in options, and fixing it](https://github.com/robertdober/earmark_parser/issues/86)

- [Parsing HTML]

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.45 

- [PR #167](https://github.com/RobertDober/earmark_parser/pull/167) refactoring Block structures into one file, thusly establishing
consistency with how Line structures are coded, [c.f. Issue #166](https://github.com/RobertDober/earmark_parser/issues/166) for
motivation.
    Kudos to [Brad Hanks](https://github.com/bradhanks)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.44 2025-03-12

- [PR #165](https://github.com/RobertDober/earmark_parser/pull/165) which formatted the code according to the newly created `.formatter.exs` **finally**
as Brad convinced me to do this. I do not particulary like all the formatter does but it is good for fututre collaboration.

**N.B. Collaborators**  `mix format --check-formatted` is part of the GHA CI checks, so please check it locally before making PRs, as duely noted in the
docs.

Maybe a commit hook would be better, I am open to suggestions.

- [PR #163](https://github.com/RobertDober/earmark_parser/pull/163) fixing [elixir-lang/ex_doc#1452](https://github.com/elixir-lang/ex_doc/issues/1452) which
was flying under my Radar waaaay to long.
    Kudos to [Brad Hanks](https://github.com/bradhanks)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.43 2025-01-24

This one is needed for OTP-28, many thanx to [José Valim](https://github.com/josevalim)
for providing the necessary PR: [Avoid regexes at compile-time as they may not be supported on OTP 28](https://github.com/RobertDober/earmark_parser/pull/162)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.42 2024-12-20

- Added runners for 1.18 to the github CI workflows

- Optimize Line Scanner by precompilation of the rgxen used, actually performance did not change
  but this was also a conceptionally cleaner refactoring.

- Remove support for Elixir 1.13 as did ex_doc

- Upgrade excoveralls and dialyxir

- [Fix deprecation warnings for Elixir 1.18 (#160)](https://github.com/RobertDober/earmark_parser/issues/160)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.41 2024-07-09

- [Fixed bug #154 parser crashes on inline ial after escaped char](https://github.com/RobertDober/earmark_parser/issues/154) 

- [Fixed GHA to catch warnings in tests](https://github.com/RobertDober/earmark_parser/pull/153)
    Kudos to [Kian-Meng Ang](https://github.com/kianmeng)

- [Fixed warnings in tests](https://github.com/RobertDober/earmark_parser/pull/152)
    Kudos to [Kian-Meng Ang](https://github.com/kianmeng)

- [Fortunately there are folks who can spell **and** type](https://github.com/RobertDober/earmark_parser/pull/151)
    Kudos to [Kian-Meng Ang](https://github.com/kianmeng)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.40 2024-07-02

- **Gladly** following [`ex_doc`](https://github.com/elixir-lang/ex_doc/blob/main/mix.exs) to drop support for
  Elixir versions < 1.13

- More Github actions with fail-on-warning to avoid the need for fixes like the one below :blush:

- [Fixed warning because of bad config of using dialxir](https://github.com/RobertDober/earmark_parser/pull/150)
    Kudos to [Jan Pieper](https://github.com/janpieper)

- [More typespecs and nicer formatting](https://github.com/RobertDober/earmark_parser/pull/146)
    Kudos to [Brad Hanks](https://github.com/bradhanks)

- [Pattern matching related refactoring](https://github.com/RobertDober/earmark_parser/pull/145)
    Kudos to [Brad Hanks](https://github.com/bradhanks)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.39 2023-11-25

- [Optional Support for Math Syntax](https://github.com/RobertDober/earmark_parser/pull/142)
    Kudos to [Jonatan Kłosko](https://github.com/jonatanklosko)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.38 2023-11-10

- [Add metadata line to inline code spans](https://github.com/RobertDober/earmark_parser/pull/140)
    Kudos to [Wojtek Mach](https://github.com/wojtekmach)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.37 2023-10-01

- [José fixed more deprecation warnings for Elixir 1.6](https://github.com/RobertDober/earmark_parser/pull/138)

- [José namespaced yecc and leex files for me <3](https://github.com/RobertDober/earmark_parser/pull/137)


## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.36 2023-09-22

- Correting deprection version for smarty_pants

- Checking for result type `EarmarkParser.t` of `EarmarkParser.as_ast`

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.35 2023-09-12

- Better error messages for bad data passed into `EarmarkParser.as_ast`

- Using minipeg instead of leaky string_lexer

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.34 2023-09-11

- PR [Strip spaces in front of code blocks](https://github.com/RobertDober/earmark_parser/pull/132)
    Kudos to [Lukas Larsson](https://github.com/garazdawi)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.33 2023-07-04

- PR [Avoid warnings in String#slice/2 with Elixir 1.16](https://github.com/RobertDober/earmark_parser/pull/128)
    Kudos to [José Valim](https://github.com/josevalim)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.32 2023-04-29

- PR [Fix of a crash on unquoted html attributes](https://github.com/RobertDober/earmark_parser/pull/127)
    Kudos to [Sebastian Seilund](https://github.com/sebastianseilund)

## [EarmarkParser](https://hex.pm/packages/earmark_parser) 1.4.31 2023-03-03

- PR [Fix catastrophic backtracking in IAL regex](https://github.com/RobertDober/earmark_parser/pull/125)
  Special Kudos for spotting **and** fixing this [Alex Martsinovich](https://github.com/martosaur)

- Bugfix for [Strikethrough not working if option `breaks: true`](https://github.com/RobertDober/earmark_parser/issues/123)
  Kudos to [Mayel de Borniol](https://github.com/mayel) for providing tests

## 1.4.30 2023-01-27

- [Fixed a problem with headers that close with # but have a # inside too ](https://github.com/RobertDober/earmark_parser/pull/122)

  Kudos to [Alex Martsinovich](https://github.com/martosaur)

- Adding a non regression test for `~` inside links (was broken earlier)

  Kudos to [Faried Nawaz](https://github.com/faried)

## 1.4.29 2022-10-20

- Bugfix for [Strike Through Only Working on start of line #115](https://github.com/RobertDober/earmark_parser/issues/115)

## 1.4.28 2022-10-01

- [Do not wrap labelled wikilinks in `<p>` tags](https://github.com/RobertDober/earmark_parser/pull/112)

  Kudos to [Ben Olive](https://github.com/sionide21)

- Add option `all: true` enabling all options which are disabled by default, which are:
            `breaks`, `footnotes`, `gfm_tables`, `sub_sup`, `wikilinks`

- Fix bug for `a^n^` not being parsed as sup

## 1.4.27 2022-09-30

- [Nice addition of sub and sup elements](https://github.com/RobertDober/earmark_parser/tree/i108-sub-and-sup)

  Needs to be enabled with the option `sub_sup: true` renders `~x~` inside `<sub>` and `^x^` inside `<sup>`

  Kudos to [manuel-rubio](https://github.com/manuel-rubio)

- Optimisation in the inline renderer

- Removal of compiler warnings

## 1.4.26 2022-06-15

- Allow unquoted values for HTML attributes

- [Accept valueless HTML attributes](https://github.com/RobertDober/earmark_parser/pull/106)

  Kudos to [Tom Conroy](https://github.com/tomconroy)

## 1.4.25 2022-03-24

- [Two PRs to assure lookahead scanning is applied on the top level, where needed most](https://github.com/robertdober/earmark_parser/issues/100)
  [and corresponding performance test](https://github.com/robertdober/earmark_parser/issues/101)

  Kudos to [jonatanklosko](https://github.com/jonatanklosko)


## 1.4.24 2022-03-20

- Single worded footnote definitions where shadowed by ID Definitions, the tiebreak was resolved in favor of
  Footnotes as ID Definitions do not need, and might as a matter of fact almost never, to start with a `^`
  [Related Issue](https://github.com/RobertDober/earmark_parser/issues/99)

- Unused import warning removed

## 1.4.23 2022-03-16

Two more list regressions fixed

- multi line inline code was ignored in the body parts of lists

- spaced lists with inline code in their bodies (single and multiline) were rendered tightly (no surrounding `<p>...</p>`

## 1.4.22 2022-03-14

Fixes all List Regressions introduced in 1.4.19

GFM support for lists remain limited (spaced and tight lists are not 100% compliant) but is better than in 1.4.18

## 1.4.21 2022-03-13

- [Paragraph context lost after indented code blocks](https://github.com/robertdober/earmark_parser/issues/98)

## 1.4.20 2022-02-21

- [Preserve newlines inside HTML code](https://github.com/RobertDober/earmark_parser/pull/97)

  Kudos to [José Valim](https://github.com/josevalim)

- [Do not remove ial on blockquote inside triple quoted](https://github.com/RobertDober/earmark_parser/pull/96)

  Kudos to [José Valim](https://github.com/josevalim)

- Removed support for Elixir 1.10 (following `ex_doc`'s lead)

- [Correct pure link regex to reject invalid characters](https://github.com/RobertDober/earmark_parser/pull/91)

  Kudos to [Akash Hiremath](https://github.com/akash-akya)

- [Intensive work to make pure links GFM Spec compliant](https://github.com/RobertDober/earmark_parser/pull/92)

  Kudos to [Akash Hiremath](https://github.com/akash-akya)

## 1.4.19 2022-01-07

- [Fix stop condition on closing HTML in scanners lookup algo](https://github.com/robertdober/earmark_parser/pull/79)

  Kudos to [José Valim](https://github.com/josevalim)

- [Typos](https://github.com/robertdober/earmark_parser/pull/78)
  Kudos to [kianmeng](https://github.com/kianmeng)

- [Footnotes fixed and upgraded(#26)](https://github.com/robertdober/earmark_parser/pull/76)

  Footnotes are now a **superset** of GFM Footnotes. This implies some changes

    - Footnote definitions (`[^footnote_id]`) must come at the end of your document (_GFM_)
    - Footnotes that are not referenced are not rendered anymore (_GFM_)
    - Footnote definitions can contain any markup with the exception of footnote definitions

## 1.4.18 2021-12-04

- [Deprecate options not useful anymore after the removal of parallel scanning (#72)](https://github.com/robertdober/earmark_parser/pull/72)

- [Do not turn off lookahead on indented fences and check for indent only once (#71)](https://github.com/robertdober/earmark_parser/pull/71)

  Kudos to [José Valim](https://github.com/josevalim)

- [Add lookahead for fenced code blocks (#70)](https://github.com/robertdober/earmark_parser/pull/70)

    * Do lookaheads for fenced code blocks

    Prior to this commit, we were trying to parse
    all lines between fenced code blocks, which
    could be very expensive. Therefore we lookahead
    fences and convert them to text.

    * Do not scan lines in parallel anymore

    * Remove unused code blocks

    * Handle fenced blocks wrapped in tags

    * Clean up regex

    * More corner cases

    * Optimize text creation

    * Optimize length checks

  Kudos to [José Valim](https://github.com/josevalim)


- [5 Whitespace after closing ATX Headers](https://github.com/robertdober/earmark_parser/issues/5)

- [40 Footnotes in lists](https://github.com/robertdober/earmark_parser/issues/40)

- [65 Bad line numbers in spaced lists](https://github.com/robertdober/earmark_parser/issues/65)

- [61 Fixes some double URI encoding in links](https://github.com/robertdober/earmark_parser/issues/61)

- [Deprecate Pedantic Option](https://github.com/robertdober/earmark_parser/pull/60)

## 1.4.17 2021-10-29

- [44 Multiple Query Params in pure links](https://github.com/robertdober/earmark_parser/issues/44)

- [28 Side By Side Reference Style Links fixed](https://github.com/robertdober/earmark_parser/issues/28)

- [52 Deprecate Smartypants Options](https://github.com/robertdober/earmark_parser/issues/52)

## 1.4.16 2021/10/07

- [Inline IALs for headers, rulers and blockquotes](https://github.com/robertdober/earmark_parser/pull/56)

- [Use Extractly instead of homemade readme task → Syntax Highlightening for iex> code blocks](https://github.com/robertdober/earmark_parser/pull/51)

- [Refactoring and Dead Code Elimination in Context](https://github.com/robertdober/earmark_parser/pull/50)

- [Annotations for Paragraphs and verbatim HTML](https://github.com/robertdober/earmark_parser/issues/47)

- [46-fixing-typos](https://github.com/RobertDober/earmark_parser/pull/46)
  Kudos to [kianmeng](https://github.com/kianmeng)

## 1.4.15 2021/08/12

- [43-add-option-to-disable-inline-parsing](https://github.com/RobertDober/earmark_parser/pull/43)
  Kudos to [jonatanklosko](https://github.com/jonatanklosko)

## 1.4.13 2021/04/18

- [37-ial-in-li-raised-key-error](https://github.com/RobertDober/earmark_parser/pull/37)

- [35-clearer-doc-iff-replacement](https://github.com/RobertDober/earmark_parser/pull/35)
  Kudos to [ream88](https://github.com/ream88)

- [33-fix-for-bad-multiclass-ial-rendering](https://github.com/RobertDober/earmark_parser/pull/33)
  Kudos to [myrrlyn](https://github.com/myrrlyn)

## 1.4.12 2020/11/27

- [29-broken-changelog-link](https://github.com/robertdober/earmark_parser/pull/29)
    Kudos to [optikfluffel](https://github.com/optikfluffel)

- [18-support-wikilinks](https://github.com/robertdober/earmark_parser/pull/18)
    Kudos to [sionide21](https://github.com/sionide21)


## 1.4.11 2020/11/26

- [24-treat-single-dash-as-text](https://github.com/robertdober/earmark_parser/issues/24)
    Kudos to [Ben Olive](https://github.com/sionide21)

- [22-missing-ws-before-links](https://github.com/robertdober/earmark_parser/issues/22)
    Kudos to [Ben Olive](https://github.com/sionide21)

## 1.4.10 2020/07/18

- [1-text-of-footnote-definitions-not-converted](https://github.com/robertdober/earmark_parser/issues/1)

- [19-use-spdx-in-hex](https://github.com/robertdober/earmark_parser/issues/19)
    Kudos to [Chulki Lee](https://github.com/chulkilee)

- [10-Missing-space-between-whitspace-separated-items](https://github.com/robertdober/earmark_parser/issues/10)

- [15-hide-private-module](https://github.com/robertdober/earmark_parser/issues/15)
      Kudos to [Wojtek Mach](https://github.com/wojtekmach)

- [14-remove-application-from-mix.exs](https://github.com/robertdober/earmark_parser/issues/14)
      Kudos to [Wojtek Mach](https://github.com/wojtekmach)

- [13-fix-github-link](https://githuhttps://github.com/RobertDober/earmark_parser/issues?q=is%3Apr+author%3Awojtekmachb.com/robertdober/earmark_parser/issues/13)
      Kudos to [Wojtek Mach](https://github.com/wojtekmach)


## 1.4.9 2020/07/01


- [2-accept-any-struct-as-option](https://github.com/pragdave/earmark/issues/2)
    Allow client code of Earmark to replace their calls to `Earmark.as_ast` with `EarmarkParser.as_ast` w/o any
    changes

## 1.4.8 2020/06/29

This marks the first release of the parser isolated from the rest of Earmark.

It is feature identical to the 1.4.7 release of Earmark.

All releases below were Earmark, all releases above are only EarmarkParser.

# Earmark

## 1.4.7 2020/06/29

- [371-still-spurious-ws-after-inline-tags](https://github.com/pragdave/earmark/issues/371)

## 1.4.6 2020/06/28

- [350-some-complicated-autolinks-cut](https://github.com/pragdave/earmark/issues/350)

- [359-unexpected-ws-in-html](https://github.com/pragdave/earmark/issues/359)

- [337-quadruple-ast-format](https://github.com/pragdave/earmark/issues/337)

- [366-simplify-transform](https://github.com/pragdave/earmark/issues/366)
    Kudos to [Eksperimental](https://github.com/eksperimental)

- [353-oneline-html-tags](https://github.com/pragdave/earmark/issues/353)

- [351-html-tags-without-newlines](https://github.com/pragdave/earmark/issues/351)

- [335-content-inside-table-cells-reversed](https://github.com/pragdave/earmark/issues/335)

- [348-no-crashes-for-invalid-URIs](https://github.com/pragdave/earmark/issues/348)
    Kudos to José Valim

- [347-dialyxir-errors](https://github.com/pragdave/earmark/issues/347)
    Fixed some of them, alas not all

## 1.4.5 2020/06/06

This is mostly a bugfix release, as there were edge cases that resulted in
Earmark crashing, notably

  - Bare IAL
  - unquoted attributes in html tags

Also autolinks (GFM extension) delivered incorrect URLS where parenthesis were involved,
for better GFM compatibility we therefore

  - Fixed broken parenthesis links (99% of all cases)
  - introduced the same URL encoding/decoding in links and link names of autolinks as GFM does

And last but not least all numeric options in the CLI can now be written with
underlines for readability.

- [343-error-parsing-unquoted-atts](https://github.com/pragdave/earmark/issues/343)

- [342 parens in pure links](https://github.com/pragdave/earmark/issues/342)

- [340 IAL might cause error](https://github.com/pragdave/earmark/issues/340)

- [339 Typos fix](ihttps://github.com/pragdave/earmark/pull/339)
    Kudos to [Ondrej Pinka](https://github.com/onpikono)

- [336 Smartypants: Convert three hyphens to em dash](https://github.com/pragdave/earmark/pull/336)
    Kudos to [Jony Stoten](https://github.com/jonnystoten)

- [324 Fix AST for links with nested elements](https://github.com/pragdave/earmark/pull/324)
    Kudos to [Wojtek Mach](https://github.com/wojtekmach)

- [320 Nested Blockquotes](https://github.com/pragdave/earmark/issues/320)

## 1.4.4 2020/05/01

- [338  Deprecation warnings in mixfile removed](https://github.com/pragdave/earmark/issues/338)

## 1.4.3 2019/11/23

- [309 fenced code allows for more than 3 backticks/tildes now](https://github.com/pragdave/earmark/issues/309)

- [302 Earmark.version returned a charlist, now a string](https://github.com/pragdave/earmark/issues/302)

- [298 Blockquotes nested in lists only work with an indentation of 2 spaces](https://github.com/pragdave/earmark/issues/298)


## 1.4.2 2019/10/14

- [296 code for tasks removed from package](https://github.com/pragdave/earmark/issues/296)
    The additional tasks are only needed for dev and have been removed from the hex package. **Finally**
- [PR#293 Nice fix for broken TOC links in README](https://github.com/pragdave/earmark/pull/293)
  Kudos to Ray Gesualdo [raygesualdo](https://github.com/raygesualdo)
- [291 Transformer whitespace inside / around &lt;code> &lt;pre> tags](https://github.com/pragdave/earmark/issues/291)
    The spurious whitespace has been removed
- [289 HTML Problem](https://github.com/pragdave/earmark/issues/289)
    The AST parser can now correctly distinguish between _generated_ AST (from md) and _parsed_ AST (from HTML)
- [288 Metadata allowed to be added to the AST](https://github.com/pragdave/earmark/issues/288)
    The default HTML Transformer ignores metadata in the form of a map with the exception of `%{meta: ...}`

## 1.4.1 2019/09/24

- [282 Always create a `<tbody>` in tables](https://github.com/pragdave/earmark/issues/282)
    Although strictly speaking a `<tbody>` is only needed when there is a `<thead>`, semantic
    HTML suggests the presence of `<tbody>` anyway.

- [281 Urls in links were URL endoded, that is actually a bug ](https://github.com/pragdave/earmark/issues/281)
    It is the markdown author's responsibility to url encode her urls, if she does so correctly
    we double encoded the url before this fix.

- [279 Languages in code blocks were limited to alphanum names, thus excluding, e.g. C# ](https://github.com/pragdave/earmark/issues/279)

- [278 Implementing better GFM Table support ](https://github.com/pragdave/earmark/issues/278)
  Because of compatility issues we use a new option `gfm_tables` defaulting to `false` for this.
  Using this option `Earmark` will implement its own table extension **+** GFM tables at the same
  time.

- [277 Expose an AST to HTML Transformer](https://github.com/pragdave/earmark/issues/277)
  While it should be faster to call `to_ast|>transform` it cannot be used instead of `as_html` yet
  as the API is not yet stable and some subtle differences in the output need to be addressed.


## 1.4.0 2019/09/05

- [145 Expose AST for output manipulation]( https://github.com/pragdave/earmark/issues/145)

- [238 Pure Links are default now]( https://github.com/pragdave/earmark/issues/238)

- [256 Align needed Elixir Version with ex_doc (>= 1.7)]( https://github.com/pragdave/earmark/issues/256)

- [259 Deprecated option `sanitize` removed]( https://github.com/pragdave/earmark/issues/259)

- [261 Deprecated Plugins removed]( https://github.com/pragdave/earmark/issues/261)

- [265 Make deprecated `Earmark.parse/2` private]( https://github.com/pragdave/earmark/issues/265)


## 1.3.6 2019/08/30

Hopefully the last patch release of 1.3 before the structural changes of 1.4.

-  [#270]( https://github.com/pragdave/earmark/issues/270)
      Error messages during parsing of table cells were duplicated in a number, exponential to the number of table cells.

-  [#268]( https://github.com/pragdave/earmark/issues/268)
      Deprecation warnings concerning pure links showed fixed link to https://github.com/pragdave/earmark, at least a reasonable choice ;),
      instead of the text of the link.

-  [#266]( https://github.com/pragdave/earmark/issues/266)
    According to HTML5 Style Guide better XHTML compatibility by closing void tags e.g. `<hr>` --&gt; `<hr />`


## 1.3.5 2019/08/01

-  [#264]( https://github.com/pragdave/earmark/issues/264)
      Expose `Earmark.parse/2` but deprecate it.

-  [#262]( https://github.com/pragdave/earmark/issues/262)
    Remove non XHTML tags <colgroup> and <col>


-  [#236]( https://github.com/pragdave/earmark/issues/236)
      Deprecation of plugins.

-  [#257]( https://github.com/pragdave/earmark/issues/257)
      Deprecation of `sanitize` option.

## 1.3.4 2019/07/29


- [#254 pure links inside links](https://github.com/pragdave/earmark/issues/254)

## 1.3.3 2019/07/23

### Bugs
- [#240 code blocks in lists](https://github.com/pragdave/earmark/issues/240)
    Bad reindentation inside list items led to code blocks not being verabtim =&rt; Badly formatted hexdoc for Earmark

- [#243 errors in unicode link names](https://github.com/pragdave/earmark/issues/243)
    Regexpression was not UTF, thus some links were not correctly parsed
    Fixed in PR [244](https://github.com/pragdave/earmark/pull/244)
    Thank you [Stéphane ROBINO](https://github.com/StephaneRob)

### Features

- [#158 some pure links implemented](https://github.com/pragdave/earmark/issues/158)
    This GFM like behavior is more and more expected, I will issue a PR for `ex_doc` on this as discussed with
    [José Valim](https://github.com/josevalim)
    Deprecation Warnings are issued by default, but will be suppressed for `ex_doc` in said PR.

-  Minor improvements on documentation
    In PR [235](https://github.com/pragdave/earmark/pull/235)
    Thank you - [Jason Axelson](https://github.com/axelson)

### Other

- Refactoring c.f. PR [246](https://github.com/pragdave/earmark/pull/246)
- Added Elixir version 1.9.0 for Travis c.f. PR #248

### Minor improvements on documentation

### PRs


  - [244](https://github.com/pragdave/earmark/pull/244)
  - [235](https://github.com/pragdave/earmark/pull/235)

### Kudos:

  - [Jason Axelson](https://github.com/axelson)
  - [Stéphane ROBINO](https://github.com/StephaneRob)


## 1.3.2 2019/03/23

* Fix for issues

  - [#224 titles might be extracted from outside link]( https://github.com/pragdave/earmark/issues/224 )
  - [#220 render only first link title always correctly]( https://github.com/pragdave/earmark/issues/220 )
  - [#218 replaced iff with longer but clearer if and only if ]( https://github.com/pragdave/earmark/issues/218 )

### Kudos:
  [niku](https://github.com/niku) for #218
  [Rich Morin](https://github.com/RichMorin) for #220 &amp; #224 as well as discussions

## 1.3.1 2018/12/21

  - [#212 spaces at line end force line break]( https://github.com/pragdave/earmark/issues/212 )
  - [#211 documentation explaining error messages]( https://github.com/pragdave/earmark/issues/211 )

## 1.3.0 2018/11/15

* Fix for issues
  - [#208 Inline code made Commonmark compatible]( https://github.com/pragdave/earmark/issues/208 )
  - [#203 escript does not report filename in error messages]( https://github.com/pragdave/earmark/issues/203 )
  - [#90 Parsing "...' or '..." as link titles removed]( https://github.com/pragdave/earmark/issues/90 )

### Dev dependencies updated

* credo -> 0.10

## 1.2.7 Not released Milestone merged into 1.3

  Special KUDOS for [pareehonos](https://github.com/pareeohnos) for a huge PR concerning the major Feature Request [#145](https://github.com/pragdave/earmark/issues/145)

  This cannot be merged yet but certainly is a great contribution to our codebase.


## 1.2.6 2018/08/21

* Fix for issues
  - [#198 Escapes inside link texts are ignored]( https://github.com/pragdave/earmark/issues/198 )
  - [#197 README task broken in Elixir 1.7]( https://github.com/pragdave/earmark/issues/197 )
  - [#191 Allow configurable timeout for parallel map]( https://github.com/pragdave/earmark/issues/191 )
  - [#190 do not include generated src/*.erl in the package]( https://github.com/pragdave/earmark/issues/190 )

* [#195 incorrect HTML for inline code blocks and IAL specified classes](https://github.com/pragdave/earmark/issues/195) from [Benjamin Milde]( https://github.com/LostKobrakai )

## 1.2.5 2018/04/02

* Fix for issues
  - [#161]( https://github.com/pragdave/earmark/issues/161 )
  - [#168]( https://github.com/pragdave/earmark/issues/168 )
  - [#172]( https://github.com/pragdave/earmark/issues/172 )
  - [#175]( https://github.com/pragdave/earmark/issues/175 )
  - [#181]( https://github.com/pragdave/earmark/issues/181 )

* [#178](https://github.com/pragdave/earmark/pull/178) from [jwworth](https://github.com/jwworth)

### Kudos:
  [jwworth](https://github.com/jwworth)

## 1.2.4 2017/11/28

* Fix for issue
  - [#166]( https://github.com/pragdave/earmark/issues/166 )

* [PR160](https://github.com/pragdave/earmark/pull/160) from [simonwebdesign](https://github.com/simonewebdesign)
* [PR163](https://github.com/pragdave/earmark/pull/163) from [nscyclone](https://github.com/nscyclone)
* [PR164](https://github.com/pragdave/earmark/pull/164) from [joshsmith](https://github.com/joshsmith)
* [PR165](https://github.com/pragdave/earmark/pull/165) from [asummers](https://github.com/asummers)

### Kudos:
   [simonwebdesign](https://github.com/simonewebdesign), [nscyclone](https://github.com/nscyclone),
   [joshsmith](https://github.com/joshsmith),  [asummers](https://github.com/asummers)


## 1.2.3 2017/07/26

* [PR151](https://github.com/pragdave/earmark/pull/151) from [joshuawscott](https://github.com/joshuawscott)

* Fixes for issues
  - [#150](https://github.com/pragdave/earmark/issues/150)
  - [#147](https://github.com/pragdave/earmark/issues/147)

### Kudos:

   [joshuawscott](https://github.com/joshuawscott)

## 1.2.2 2017/05/11

* [PR #144](https://github.com/pragdave/earmark/pull/144) from [KronicDeth](https://github.com/KronicDeth)

### Kudos:

  [KronicDeth](https://github.com/KronicDeth)

## 1.2.1 2017/05/03

* [PR #136](https://github.com/pragdave/earmark/pull/136) from [chrisalley](https://github.com/chrisalley)

* Fixes for issues
  - [#139](https://github.com/pragdave/earmark/issues/139)

### Kudos:

  [chrisalley](https://github.com/chrisalley)

## 1.2 2017/03/10

*  [PR #130](https://github.com/pragdave/earmark/pull/130) from [eksperimental](https://github.com/eksperimental)
*  [PR #129](https://github.com/pragdave/earmark/pull/129) from [Alekx](https://github.com/alkx)
*  [PR #125](//https://github.com/pragdave/earmark/pull/125) from [vyachkonovalov](https://github.com/vyachkonovalov)

* Fixes for issues
  - #127
  - #131

### Kudos:

  [vyachkonovalov](https://github.com/vyachkonovalov), [Alekx](https://github.com/alkx), [eksperimental](https://github.com/eksperimental)

## 1.1.1 2017/02/03

* PR from Natronium pointing out issue #123

* Fixes for issues
  - #123

### Kudos:

  [Natronium](https://github.com/Natronium)

## 1.1.0 2017/01/22

* PR from Michael Pope
* PR from Pragdave
* PR from christopheradams
* PR from [AndrewDryga](https://github.com/AndrewDryga)

* Fixes for issues
  - #106
  - #110
  - #114

### Kudos:
  [AndrewDryga](https://github.com/AndrewDryga), [Christopher Adams](https://github.com/christopheradams),
  [Michael Pope](https://github.com/amorphid)


## 1.0.3 2016/11/02

* PR from TBK145 with some dead code elimination.
* Implementation of command line switches for the `earmark` executable. Now any `%Earmark.Options{}` key can be
  passed in.

* Fixes for issues
  - #99
  - #96
  - #95
  - #103

### Kudos:
  Thijs Klaver (TBK145)

## 1.0.2 2016/10/10

* PR from pdebelak with a fix of #55
* PR from jonnystorm with a fix for a special case in issue #85
* test coverage at 100%
* PR from michalmuskala
* Fixed remaining compiler warnings from 1.0.1 (Elixir 1.3)
* PR from pdebelak to fix a factual error in the README
* Fixes for issues
  - #55
  - #86
  - #88
  - #89
  - #93

### Kudos:
  Jonathan Storm (jonnystorm), Michal Muskala (michalmuskala) & Peter Debelak (pdebelak)

## 1.0.1  2016/06/07

* fixing issue #81 by pushing this updated Changelog.md :)
* PR from mschae fixing issue #80 broken hex package

### Kudos:
  Michael Schaefermeyer (mschae) & Tobias Pfeiffer (PragTob)

## 1.0.0  2016/06/07

* --version | -v switch for `earmark` escript.
* added security notice about XSS to docs thanks to remiq
* PR from alakra (issue #59) to allow Hyphens and Unicode in fenced code block names
* PR from sntran to fix unsafe conditional variables from PR
* PR from riacataquian to use maps instead of dicts
* PR from gmile to remove duplicate tests
* PR from gmile to upgrade poison dependency
* PR from whatyouhide to fix warnings for Elixir 1.4 with additional help from milmazz
* Travis for 1.2.x and 1.3.1 as well as OTP 19
* Fixes for issues:
  - #61
  - #66
  - #70
  - #71
  - #72
  - #77
  - #78

### Kudos:
Remigiusz Jackowski (remiq), Angelo Lakra (alakra), Son Tran-Nguyen (sntran), Mike Kreuzer (mikekreuzer),
Ria Cataquian (riacataquian), Eugene Pirogov (gmile), Andrea Leopardi (whatyouhide) & Milton Mazzarri (milmazz)

## 0.2.1  2016/01/15

* Added 1.2 for Travis
* PR from mneudert to fix HTMLOneLine detection

### Kudos:

Marc Neudert (mneudert)


## 0.2.0  2015/12/28

* PR from eksperimental guaranteeing 100% HTML5
* PR from imbriaco to decouple parsing and html generation and whitespace removal
* Fixes for issues:
  - #40
  - #41
  - #43
  - #48
  - #50
  - #51
* Explicit LICENSE change to Apache 2.0 (#42)
* Loading of test support files only in test environment thanks to José Valim
* IO Capture done correctly thanks to whatyouhide
* Warning for Elixir 1.2 fixed by mschae

### Kudos:

Eksperimental (eksperimental), Mark Imbriaco (imbriaco), Andrea Leopardi(whatyouhide), José Valim &
Michael Schaefermeyer (mschae)

## 0.1.19 2015/10/27

* Fix | in implicit lists, and restructur the parse a little.
  Many thanks to Robert Dober

## 0.1.17 2015/05/18

* Add strikethrough support to the HTML renderer. Thanks to
  Michael Schaefermeyer (mschae)


## 0.1.16 2015/05/08

* Another fix from José, this time for & in code blocks.


## 0.1.15 2015/03/25

* Allow numbered lists to start anywhere in the first four columns.
  (This was previously allowed for unnumbered lists). Fixes #13.


## 0.1.14 2015/03/25

* Fixed a problem where a malformed text heading caused a crash.
  We now report what appears to be malformed Markdown and
  continue, processing the line as text. Fixes #17.


## 0.1.13 2015/01/31

* José fixed a bug in Regex that revealed a problem with some
  Earmark replacement strings. As he's a true gentleman, he then
  fixed Earmark.


## 0.1.11 2014/08/18

* Matthew Lyon contributed footnote support.

      the answer is clearly 42.[^fn-why] In this case
      we need to…

      [^fn-why]: 42 is the only two digit number with
                 the digits 4 and 2 that starts with a 4.

  For now, consider it experimental. For that reason, you have
  to enable it by passing the `footnotes: true` option.


## 0.1.10 2014/08/13

* The spec is ambiguous when it comes to setext headings. I assumed
  that they needed a blank line after them, but common practice says
  no. Changed the parser to treat them as headings if there's no
  blank.


## 0.1.9 2014/08/05

* Bug fix—extra blank lines could be appended to code blocks.
* Tidied up code block HTML


## 0.1.7 2014/07/26

* Block rendering is now performed in parallel


## 0.1.6 07/25/14

* Added support for Kramdown-style attribute annotators for all block
  elements, so you can write

        # Warning
        {: .red}

        Do not turn off the engine
        if you are at altitude.
        {: .boxed #warning spellcheck="true"}

  and generate

        <h1 class="red">Warning</h1>
        <p spellcheck="true" id="warning" class="boxed">Do not turn
        off the engine if you are at altitude.</p>


## 0.1.5 07/20/14

* Merged two performance improvements from José Valim
* Support escaping of pipes in tables, so

        a  |  b
        c  |  d \| e

  has two columns, not three.


## 0.1.4 07/14/14

* Allow list bullets to be indented, and deal with potential subsequent
  additional indentation of the body of an item.


## 0.1.3 07/14/14

* Added tasks to the Hex file list


## 0.1.2 07/14/14

* Add support for GFM tables


## 0.1.1 07/09/14

* Move readme generation task out of mix.exs and into tasks/
* Fix bug if setext heading started on first line


## 0.1.0 07/09/14

* Initial Release
