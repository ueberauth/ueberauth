# Changelog

## v0.40.3 (2026-05-21)

  * Enhancements
    * Add autolinking for Erlang/OTP 29 native records

## v0.40.2 (2026-05-08)

  * Bug fixes
    * Add `rel="nofollow"` to external links in HTML output
    * Use blockquote in `llms.txt` description
    * Void elements in `epub`, such `wbr`, must be terminated by the matching end-tag
    * Fix content container scrolling in older versions of Safari
    * Skip HTML comments when computing synopsis
    * Fix markdown backend code fence language and opaque type display
    * Fix false positive warning when linking to asset files
    * Prevent `#search` selector from impacting user content
    * Raise on extras that conflict with reserved filenames
    * Fix styling of admonition blocks

## v0.40.1 (2026-01-31)

  * Enhancements
    * Remove link to source from generated .md files
    * Improve word-breaking of module names and sizing of main page titles
    * Include description in llms.txt

  * Bug fixes
    * Fix headers in custom groups

## v0.40.0 (2026-01-20)

  * Enhancements
    * Introduce Markdown formatter (thanks to Yordis Prietro)
    * Generate a `llms.txt` document by default and add a "Copy Markdown" button to the top of every page
    * Run retriever only once per formatter
    * Support anchors on redirects

  * Bug fixes
    * Copy button on `erl` and `iex` snippets now include prompts
    * Fix headers having wrong selectors due to whitespace minification
    * Only include `.html` links on Swup

  * Breaking changes
    * Revamp the ExDoc entrypoint and formatter API. While those have never been made public, others may have relied on it. We have now changed and documented them on the path to standardization
    * The previously deprecated :assets option will raise if given a string, pass a map instead

## v0.39.3 (2025-12-09)

  * Enhancements
    * Add the option to trim down the footer

## v0.39.2 (2025-12-04)

  * Bug fixes
    * Do not strip hrefs on summaries
    * Show go to latest for prereleases
    * Prevent fake italic in autocomplete text
    * Rename "Search Hexdocs" link to "Go to package docs"

## v0.39.1 (2025-10-23)

  * Bug fixes
    * Improve box-shadow around autocompletion
    * Trim search engine selector on small screens
    * Fix admonition titles on small screens

## v0.39.0 (2025-10-23)

  * Enhancements
    * Allow custom search engines to be configured with support for `https://hexdocs.pm`
    * Improve admonition blocks so they better integrate with the page flow
  * Bug fixes
    * Add .cheatmd to EPUB to avoid broken links
  * Backwards incompatible changes
    * Validate :extras fields: if you were previously setting them to unexpected values, you may now get an exception
    * Setting `exdoc:full-text-search-url` metadata is no longer supported, using the new search engines configuration

## v0.38.4 (2025-09-09)

  * Bug fixes
    * Fix escaping of links when they have ampersand in them
    * Increase spacing of footers in pages
    * Align stale icon positioning

## v0.38.3 (2025-08-17)

  * Enhancements
    * Allow configuring autocomplete limit, and default it to 10 instead of 8
    * Display description text in docs groups
    * Load discovered makeup apps for CLI

## v0.38.2 (2025-05-27)

  * Bug fixes
    * Render documents with hardcoded `<h2>`/`<h3>` entries correctly
    * Fix padding on external links

## v0.38.1 (2025-05-12)

  * Bug fixes
    * Ensure stripping apps for Erlang sources emit valid AST

## v0.38.0 (2025-05-09)

  * Enhancements
    * Allow listing outside URLs in extras

  * Bug fixes
    * Ensure some cases where `<`, `>`, `&` and in headers would appear as entities in the sidebar
    * Fix outline caused by swup.js on Webkit based browsers
    * Fix bugs when computing synopsis
    * Automatically close the sidebar when navigating sections on mobile

## v0.37.3 (2025-03-06)

  * Bug fixes
    * Handle `http-equiv=refresh` during Swup.js navigation
    * Include full error description when syntax highlighting fails

## v0.37.2 (2025-02-19)

  * Bug fixes
    * Fix code highlighting for languages with non-alphanumeric characters

## v0.37.1 (2025-02-10)

  * Enhancements
    * Support umbrella projects via the CLI

  * Bug fixes
    * Make sure docs are rendered inside iframes

## v0.37.0 (2025-02-05)

Thanks to @liamcmitchell and @hichemfantar for the extensive contributions in this new release.

  * Enhancements
    * Optimize and parallelize module retriever, often leading to 20x-30x faster docs generation
    * Considerably improve page loading times in the browser
    * Allow customizing `search_data` for extra pages
    * Use native style for scroll bars
    * Enhance links between extras/pages/guides with padding and hover effects
    * Go to latest goes to the same page if it exists, root otherwise
    * Apply new style and layout for tabs
    * Increase font-weight on sidebar on Apple machines/devices
    * Improve accessibility across deprecation, links, and summaries
    * Add compatibility to Erlang/OTP 28+
    * Rely on the operating system monospace font for unified experience and better load times
    * Introduce `"exdoc:loaded"` window event to track navigation
    * Support for favicons

  * Bug fixes
    * Move action links out from heading tags

## v0.36.1 (2024-12-24)

  * Enhancements
    * Show a progress bar if navigation takes more than 300ms

  * Bug fixes
    * Fix dark mode styling on cheatsheets
    * Ensure the sidebar closes on hosting navigation in mobile

## v0.36.0 (2024-12-24)

  * Enhancements
    * Use swup.js for navigation on hosted sites
    * Support `:group` in documentation metadata for grouping in the sidebar
    * Support `:default_group_for_doc` in configuration to set the default group for functions, callbacks, and types
    * Add `--warnings-as-errors` flag to `mix docs`

  * Bug fixes
    * Fix typespec with `(...) -> any()`
    * Do not trap `tab` commands in the search bar

## v0.35.1 (2024-11-21)

  * Bug fixes
    * Make sure symlinks are copied from assets directory
    * Discard private functions documented by EDoc

## v0.35.0 (2024-11-19)

  * Enhancements
    * Store `proglang` in `searchdata.js`
    * Allow searching for atoms inside backticks
    * Add support for nominal types from Erlang/OTP 28
    * Support a new `:redirects` option which allows configuring redirects in the sidebar
    * Improve warning when referencing type from a private module
    * Rename "Search HexDocs package" modal to "Go to package docs"
    * Support built-in Erlang/OTP apps in "Go to package docs"

  * Bug fixes
    * Switch anchor `title` to `aria-label`
    * Convert admonition blockquotes to sections for screen reader users
    * Fix code copy buttons within tabsets

## v0.34.2 (2024-07-08)

  * Enhancements
    * Allow anchors on function and callback autolinks

  * Bug fixes
    * Make module attributes searchable without leading @
    * Make Mod.fun pairs searchable without the arity
    * Do not emit warnings on unary plus in typespecs
    * Add top margin to nested module prefix in sidebar

## v0.34.1 (2024-06-30)

  * Enhancements
    * Add a `v` shortcut to open/focus the version select
    * Compatibility fixes for Elixir v1.17 and Erlang/OTP 27+

  * Bug fixes
    * Do not crash on unknown media types in assets during EPUB generation
    * Fix slight shift on search bar input during focus
    * Avoid unwanted showing/hiding of search bar on mobile when scrolling

## v0.34.0 (2024-05-30)

This release requires Elixir v1.13.

  * Enhancements
    * Allow several assets to be copied by passing a map to `:assets`
    * Improve compatibility when hosting ExDoc on a platform that strips `.html`

  * Bug fixes
    * Link to the latest version of Erlang/OTP docs

  * Deprecations
    * Deprecate passing a binary to `:assets`

## v0.33.0 (2024-05-21)

  * Enhancements
    * Keep the sidebar light in light mode

## v0.32.2 (2024-05-10)

  * Enhancements
    * Allow the modal to close when we click outside the modal content

  * Bug fixes
    * Fix indentation of -spec/-type in Erlang
    * Fix Mix task autolink for tasks with underscores
    * Avoid conflicts between custom headers with tooltips/modals

## v0.32.1 (2024-04-12)

  * Bug fixes
    * Add version dropdown back on hexdocs.pm
    * Improve search input styling and scrolling

## v0.32.0 (2024-04-10)

  * Enhancements
    * Add the ability to see previews during autocompletion
    * Remove serif font for content and prefer using the operating system font instead
    * Allow the search bar to be focused at any moment
    * Make functions acceptable for `:skip_undefined_reference_warnings_on`
    * Make functions acceptable for `:skip_code_autolink_to`
    * Allow using meta tags to disable autocompletion and configure the full text search

  * Bug fixes
    * Fix blockquote padding inside tabset on small screens
    * Consistently index h2 and h3 headers

## v0.31.2 (2024-03-05)

  * Enhancements
    * Add `equiv` handling for types and callbacks for Erlang
    * Add cmd-k/ctrl-k shortcut to focus searchbar
    * Use dark backgrounds for admonition blocks in dark theme
    * Autolink .cheatmd files
    * Warn when extra link targets an application not in dependencies
    * Add support for `before_closing_footer_tag`

  * Bug fixes
    * Fix sidebar toggle flickering on page load
    * Fix background color inside code snippets with no language in dark mode
    * Hide search bar and background layer on print
    * Use blue links for Erlang
    * Fix logo not declared in EPUB's OPF manifest
    * Escape URIs and titles in EPUB
    * Fix URL slug not updating on anchor clicks

## v0.31.1 (2024-01-11)

  * Enhancements
    * Make the sidebar horizontally resizable
    * Show the sidebar button and search bar on scroll up on mobile devices
    * More improvements to Erlang/OTP 27 support
    * Document that `source_url_pattern` can be a fun
    * Support `m:Module#anchor`

## v0.31.0 (2023-12-11)

  * Enhancements
    * Allow searching atoms, module attributes, and words finishing with `?` and `!`
    * Support upcoming Erlang/OTP 27 documentation format
    * Include prebuilt binaries on every release
    * Add borders dividing table rows in rendered content
    * Add accurate warnings for missing docs from Elixir v1.16+
    * Support `e:dep:some-page.md` for explicitly linking to a page in a package
    * Support `m:SomeModule` for explicitly linking to a module
    * Add `noindex` meta tag to 404 and Search pages
    * Move search to the main content so we can display more results
    * Warn when referencing functions, types, and callbacks from filtered out modules

  * Bug fixes
    * Fix search for words with hyphens in them
    * Fix search for contents inside EEx interpolation

## v0.30.9 (2023-10-20)

  * Bug fixes
    * Fix a scenario where invalid assets would be generated

  * Enhancements
    * Add admonition EPUB styles

## v0.30.8 (2023-10-17)

  * Bug fixes
    * Fix regression in umbrella applications

## v0.30.7 (2023-10-15)

  * Bug fixes
    * Do not crash on EDoc type annotations
    * Do not crash on functions without name
    * Handle remote types in records
    * Fix scrolling to top on iOS
    * Fix invalid output markup for “hover link” headings

  * Enhancements
    * Support any String.Chars as the extra page name
    * Improve screen reader accessibility
    * Add `:skip_code_autolink_to` option

## v0.30.6 (2023-08-25)

  * Enhancements
    * Extract title from Markdown file when preceded with comments
    * Improve focus navigation in notebooks

## v0.30.5 (2023-08-12)

  * Bug fixes
    * Fix style for code in headers
    * Fix search data generation for Erlang/OTP

## v0.30.4 (2023-08-03)

  * Bug fixes
    * Fix style for anchors in headers

## v0.30.3 (2023-07-15)

  * Enhancements
    * Compress search index before storing in local storage

  * Bug fixes
    * Fix styling for headers on cheatsheets and small screens

## v0.30.2 (2023-07-11)

  * Bug fixes
    * Fix escaping in `search_data.json`
    * Skip vega-lite code blocks in `search_data.json`

## v0.30.1 (2023-07-07)

  * Bug fixes
    * Fix styling for headers on cheatsheets and small screens

## v0.30.0 (2023-07-07)

  * Enhancements
    * Support tabsets (see the README for more information)
    * Improve search results and indexing by storing more data and metadata
    * Warn on invalid references in links
    * Strike-through deprecated items on autocompletion
    * Add source URL link to API reference page
    * Allow multiple extra files with the same name by generating unique names in case of conflicts

  * Bug fixes
    * Fix rendering of large code blocks in admonition texts
    * Do not log errors on module mismatch in case-insensitive file systems

## v0.29.4 (2023-03-29)

  * Bug fixes
    * Fix sidebar element with no children taking additional padding
    * Fix elements being rendered too thick on macOS
    * Fix rendering of HTML elements inside tooltips

## v0.29.3 (2023-03-17)

  * Enhancements
    * Propagate `:since` metadata from modules
    * Add support for MFAs and maps in `before_closing_body_tag` and `before_closing_head_tag`

  * Bug fixes
    * Improve font consistency across different OSes
    * Keep language class on livebook output code block
    * Ensure switches have higher precedence than config

## v0.29.2 (2023-03-02)

  * Enhancements
    * Improvements to cheatsheets spacing
    * Improvements to cheatsheets print
    * Include sections of modules and extras in search suggestions
    * Make sidebar links full-width and add hover states
    * Improve clickable area of sidebar tabs
    * Improve contrast on sidebar

  * Bug fix
    * Add media type for .license files for epub
    * Fix overscroll on the sidebar
    * Focus search input immediately after keyboard shortcut
    * Don't attempt parsing code blocks that don't look like modules
    * Fix visited link color in admonition blocks

## v0.29.1 (2022-11-21)

  * Enhancements
    * Add optional function annotations
    * Support media print on stylesheets
    * Add download ePub link to footer
    * Support extras for Erlang
    * Add tooltip to functions on sidebar
    * Disable spellcheck and autocorrect on search input

  * Bug fix
    * Special handle functions called `record/*` in Erlang

  * Deprecations
    * Rename `:groups_for_functions` to `:groups_for_docs`

## v0.29.0 (2022-10-19)

  * Enhancements
    * Support cheatsheets as `.cheatmd` files

  * Bug fix
    * Collapse sidebar when resizing page even if stored in the session as opened

## v0.28.6 (2022-10-13)

  * Enhancements
    * Add Elixir special punctuation ! and ? to natural sort
    * Add night mode to settings pane
    * Support --proglang in mix docs
    * Save sidebar state per session
    * Distinguish output code blocks in Livebooks

  * Bug fixes
    * Prevent sidebar button scrolling out of view
    * Prevent unreadable text when using inline code with admonition headers

## v0.28.5 (2022-08-18)

  * Enhancements
    * Do not preserve spaces from spec declaration in signature rendering
    * Index hyphens in search
    * Index `@` in search
    * Change minimal package search length to 2

  * Bug fixes
    * Remove extra `term()` argument at start of `@macrocallback`

## v0.28.4 (2022-04-28)

  * Enhancements
    * Add a toast when changing theme via keyboard
    * Automatically convert `.livemd` links to `.html` ones
    * Show programming language in HTML footer

  * Bug fixes
    * Properly escape `%/2` special form
    * Improve ranking of exact-matching modules in search

## v0.28.3 (2022-03-23)

  * Enhancements
    * Include page titles in autocomplete suggestions
    * Allow theme to be set to "System" version
    * Remove "Specs" heading and render full typespecs
    * Support for `source_url_pattern` in config being a function

  * Bug fixes
    * Adjustments for blockquotes and admonition blocks in dark mode
    * Fix module sorting when a list of dirs is provided
    * Consider casing of letters when sorting items in the menu, summary, function list, etc

## v0.28.2 (2022-02-23)

  * Bug fixes
    * Fix links and code tags in admonition text blocks for dark mode

## v0.28.1 (2022-02-20)

  * Enhancements
    * Add support for admonition text blocks
    * Improve accessibility for light and dark themes

  * Bug fixes
    * Ensure that `mix docs --open` works on Windows
    * Ensure search tokenizer also splits on underscore
    * Fix false warnings about missing types when running ExDoc in escript mode
    * Don't navigate when clicking the current page

## v0.28.0 (2022-01-24)

ExDoc v0.28.0 requires Elixir v1.11+.

  * Enhancements
    * Use custom scrollbar in the sidebar
    * Keep hamburger absolute to the opened sidebar
    * Support `--open` flag on `mix docs`
    * The copy button now only copies selectable content

  * Bug fixes
    * Make sure filename configuration in `:extras` is used across links
    * Ensure all `extras` pages have a title generated
    * Fix margin on 3rd level headers and beyond
    * Ensure a task that defines callbacks is still listed as a task

## v0.27.3 (2022-01-12)

  * Bug fixes
    * Make HexDocs search case insensitive
    * Improve sidebar open/close animation

## v0.27.2 (2022-01-11)

  * Bug fixes
    * Fix version dropdown when hosted on HexDocs
    * Fix tooltips
    * Fix JavaScript error when Hex package information is not available

## v0.27.1 (2022-01-11)

  * Bug fixes
    * Several usability fixes on the new layout
    * Keep page ordering

## v0.27.0 (2022-01-11)

  * Enhancements
    * Introduce new sidebar design
    * Add `--quiet` option to CLI
    * Support multiple formatters in the CLI
    * Show structs as `%Struct{}` instead of `__struct__` in the sidebar
    * Point Erlang links to `www.erlang.org` instead of `erlang.org`
    * Improvements to the night mode and styling

## v0.26.0 (2021-11-21)

  * Backwards incompatible changes
    * `:filter_prefix` has been renamed to `:filter_modules` and supports anonymous functions
    * `:source_ref` now defaults to `"main"`
    * Dropped support for smartypants in Markdown

  * Bug fixes
    * Do not warn on links to sections

  * Enhancements
    * Add copy button to code snippets
    * Add `translate="no"` to the relevant attributes to improve interoperability with automatic translation tools
    * Support optional module annotations
    * Introduce a settings modal to group most of configuration
    * Allow customizing the Livebook expansion URL
    * Provide documentation on how to render plugins such as Katex, VegaLite, and Mermaid

## v0.25.5 (2021-10-20)

  * Bug fixes
    * Do not duplicate API Reference title
    * Update assets for Livebook badge functionality

## v0.25.4 (2021-10-20)

  * Enhancements
    * Add source link to pages in `:extras`
    * Add "Run in Livebook" badge to `.livemd` pages in `:extras`

  * Bug fixes
    * Do not generate entries for private Erlang functions
    * Do not trim `?` and `!` from Elixir tokens on search

  * Incompatible changes
    * Remove unused `:source_root` option

## v0.25.3 (2021-09-21)

  * Enhancements
    * Track user preference for sidebar state

  * Bug fixes
    * Do not double escape page titles on the sidebar
    * Do not fail when documenting cover compiled modules
    * Don't crash upon doc chunks for unknown beam languages

## v0.25.2 (2021-09-02)

  * Enhancements
    * Add support for Livebook's `.livemd` Markdown files
    * Preload all applications starting with `makeup_` before doc generation
    * Add Hex package config and display "Find on Hex" footer links

## v0.25.1 (2021-08-02)

  * Enhancements
    * Supporting grouping of callbacks
    * Use shell lexer for code blocks with no language and starting with `$ `

  * Bug fixes
    * Fix generating type signatures with maps
    * Skip Erlang modules that have empty docs
    * Skip Erlang functions that have empty docs
    * Fix accidentally showing shape of opaque types

## v0.25.0 (2021-07-20)

  * Enhancements
    * Handle remote types when generating signatures, e.g. `@callback callback1(GenServer.options())` becomes `callback1(options)`
    * Support Markdown processor options
    * Add `--paths` command line argument to prepend directories to the code path when generating docs
    * Make shell prompt, `$ `, not selectable for `shell`, `sh`, `bash` and `zsh` code blocks

  * Bug fixes
    * Fix custom links to undefined/hidden references
    * Fix generating external links with `:deps` configuration
    * Add ellipsis to more sections

  * Backwards incompatible changes
    * Remove function landing pages

## v0.24.2 (2021-04-06)

  * Enhancements
    * Support stepped range syntax

  * Bug fixes
    * Add spaces on paragraph endings for search results
    * Fix bug defining app name in config
    * Fix rendering void elements (`<br>` etc)

## v0.24.1 (2021-03-22)

  * Bug fixes
    * Fix generating function landing pages

## v0.24.0 (2021-03-16)

  * Enhancements
    * Drop jQuery and refactor JavaScript codebase
    * Remove highlight.js in favour of migration to Makeup
    * Change autolink to return both path and hash for the current module
    * Add next/previous at the end of extra pages
    * Improve search input blur handling
    * Update erlang.org/man URL
    * Add function landing page

  * Bug fixes
    * Ignore extensions when generating external links
    * Fix autolink to handle URIs with arbitrary scheme part without warning
    * Fix undefined reference warning for typespecs
    * Fix search click behavior when a suggestion refers the current page
    * Don't crash when we can't format spec
    * Fix HTML escaping

## v0.23.0 (2020-10-12)

Requires Elixir v1.10.

  * Enhancements
    * Improve warnings on broken references
    * Support Elixir v1.12-dev

  * Bug fixes
    * Respect deps config in autolink
    * Fix html escaping in the sidebar entries
    * Fix retrieving specs for macros with `when`
    * Raise if none of :name or :app are found in mix.exs
    * Don't crash on code blocks like "A.b.C"

## v0.22.6 (2020-09-16)

  * Bug fixes
    * Properly fix CSS bug on headings
    * Add expansion arrow to sections on sidebar

## v0.22.5 (2020-09-13)

  * Bug fixes
    * Fix CSS bug on headings

## v0.22.4 (2020-09-12)

  * Enhancements
    * Improve accessibility and add aria labels
    * Show different title and message for a empty search value

## v0.22.3 (2020-07-25)

  * Bug fixes
    * [HTML+EPUB] Remove overlapping functions from defaults
    * [HTML] Don't show tooltip for module sections and non-html files
    * [HTML] Make sure tooltips work with escape ids.

## v0.22.2 (2020-07-20)

  * Enhancements
    * [HTML+EPUB] Add support for path dependent markdown autolink (`feeddc1`)
    * [HTML+EPUB] Improve auto-linking to callbacks and types (`12c0a01`)
    * [HTML+EPUB] Replace `<kbd>` with `<kbd><kbd>` when it represents keys to be hit (`bd2b8df`)
    * [HTML] Hide sidebar-over-content on click/tap outside it (`b050775`)
    * [HTML] Redirect to correct file when changing version (`0f6f24b`)
    * [mix docs] Allow files with no extension in extra files (`26b93b6`)
    * [mix docs] Link to siblings in an umbrella (`b0d6fdd`)
    * [mix docs] Switch to `earmark_parser`. Run `mix deps.unlock --unused` to remove the now
      unused `earmark` dependency. (`021c772`)

  * Bug fixes
    * [HTML+EPUB] Bring back auto-linking to Kernel and Kernel.SpecialForms (`fa174eb`)
    * [HTML+EPUB] Escape HTML special characters in signature (`5fed479`)
    * [HTML+EPUB] Fix auto-linking `./2` and `../2` (`2e40acb`)
    * [HTML+EPUB] Fix list of basic types to auto-link (`6df4a3b`)
    * [HTML+EPUB] Make HTML valid (`1187ace`)
    * [HTML] Escape HTML special characters in sidebar (`d26ca71`)
    * [HTML] Fix keyboard shortcuts on non US keyboard layouts (`829c4ee`)
    * [HTML] Fix text overflow in sidebar (`a4ff547`)
    * [HTML] Handle snake case terms in search results (`d511d55`)
    * [mix docs] Don't crash on markdown that triggers warning (`e7cb79c`)

## v0.22.1 (2020-05-19)

  * Bug fixes
    * [mix docs] Depend on earmark `~> 1.4.0`
    * [mix docs] Don't crash on comments in markdown
    * [mix docs] Don't crash on HTML in markdown

## v0.22.0 (2020-05-11)

  * Enhancements
    * [EPUB] Add epub to the default formatters
    * [HTML+EPUB] Move specs out of signature
    * [HTML+EPUB] Auto-link "erlang" types & callbacks
    * [HTML+EPUB] Auto-link "erlang" modules in custom links
    * [mix docs] Warn on broken references in dependencies (e.g. `` `String.upcase/9` ``)
    * [escript] Add `--app`
    * [HTML+EPUB] Auto-link to extras (e.g. `[foo](foo.md)`)
    * [mix docs] Undefined references warning now includes the filename
    * [mix docs] `:skip_undefined_reference_warnings_on` now also accepts a filename
    * [HTML+EPUB] Display moduledoc headings in the sidebar

  * Bug fixes
    * [HTML] Fix hidden text selection, hide tooltips for details link
    * [HTML+EPUB] Fix function name sorting (group operators together)
    * [HTML+EPUB] Fix displaying nested modules

  * Backwards incompatible changes
    * [mix docs] Remove built-in support for cmark markdown processor
    * [mix docs] Replace `ExDoc.Markdown.to_html/2` with `to_ast/2`
    * [HTML+EPUB] Remove auto-linking for local calls to Kernel & Kernel.SpecialForms,
      use fully qualified calls instead. (e.g. replace `` `==/2` `` with `` `Kernel.==/2` ``.)
    * [mix docs] `:skip_undefined_reference_warnings_on` no longer accepts extras id, use
      extras filename instead.

## v0.21.3

  * Enhancements
    * [HTML] Make "Exceptions" a module sub-grouping instead of a top-level group
    * [HTML] Automatically group deprecated modules
    * [HTML] Rely on `prefers-color-scheme` w/o night mode set
    * [HTML] Boost title on search results, add fun/arity to title
    * [mix docs] Initial work on support for multiple languages

  * Bug fixes
    * [HTML] Many improvements to the search engine
    * [mix docs] Link to callback docs instead of copying them

## v0.21.2

  * Enhancements
    * [HTML] Add hardcoded packages to the quick-switch search results
    * [HTML] Filter out packages without docs on HexDocs in quick-switch
    * [HTML+EPUB] Support autolinking for multiple arities
    * [mix docs] Avoid deprecation warnings on more recent earmark versions
    * [mix docs] Warn on unavailable local functions
    * [mix docs] Make invalid index redirect warning case-sensitive
    * [mix docs] Ignore non-Elixir modules when missing chunk

  * Bug fixes
    * [HTML+EPUB] Do not create a custom link when destination does not exist
    * [EPUB] Hide screen reader elements

## v0.21.1

  * Bug fixes
    * [HTML] Make sure package selector can be reopened after closed with `ESC`
    * [HTML] Ensure tooltip pages can be cached
    * [HTML] Support large version numbers on the version dropdown
    * [mix docs] Raise nice exception for missing ExDoc.Config

## v0.21.0

  * Enhancements
    * [HTML] Add support for reference popovers
    * [HTML] Provide a "g" shortcut to Go To a Hexdocs package (with autocomplete)
    * [HTML] Detect if browser prefers night mode
    * [EPUB] Add support for covers and the authors field

  * Bug fixes
    * [HTML+EPUB] Ensure that link headers generate unique IDs
    * [HTML+EPUB] Sort structs fields so field names are always ordered
    * [HTML+EPUB] Do not strip "Elixir." prefix from module names
    * [HTML] Support URLs with non-HTML safe characters
    * [EPUB] Fix table of contents without groups

## v0.20.2

  * Enhancements
    * Add "mix " prefix to Mix tasks

  * Bug fixes
    * Improve scrolling on Safari
    * Prevent text casing of codes
    * Do not remove stop words from search and make sure function names are searchable in isolation
    * Reduce the size of the search metadata
    * Remove outline on focus and keep width in version dropdown
    * Do not fail if we can't persist index

## v0.20.1

  * Bug fixes
    * Hide the spinner when no term is searched
    * Use `?` for the shortcut hint text
    * Improve style of the version dropdown

## v0.20.0

  * Enhancements
    * Rework the search bar to provide autocompletion
    * Provide full-text search
    * Automatically generate documentation for `defdelegate` definitions (requires Elixir v1.8+)
    * Provide keyboard shortcuts (press `?` to see all available outputs) or click the link at the bottom of the page
    * Add support for versions dropdown to the HTML sidebar. This requires adding a `docs_config.js` (also configurable) that sets a `versionNodes` JavaScript variable.
    * Improve mouseover titles on sidebar navigation

  * Bug fixes
    * Do not hide structs in type/callback summary signatures
    * No longer require double click to open up a sidebar on Mobile Safari
    * Keep trailing periods in summaries
    * Fix typespec `arg` number to start from 1 instead of 0

## v0.19.3

  * Enhancements
    * Include a "goto" link on mouseover for expandable menu items

  * Bug fixes
    * Always expand menu items, even if has a single child
    * Fix sidebar bottom margin on Firefox
    * Fix anchor links sometimes not working by moving JS to HTML head
    * Unify code styling for makeup and hljs
    * Do not replace the content of custom links pointing to Elixir modules
    * Remove border-left on deprecated to not mistake it with a heading

## v0.19.2

  * Enhancements
    * Allow logo in SVG extension
    * Allow functions to be grouped based on metadata
    * Allow api-reference.html page to be disabled
    * Allow nesting of modules by prefix
    * Autolink `mix help TASK`
    * Warn on undefined remote functions from project's docs

  * Bug fixes
    * Sort function names alphabetically in the sidebar
    * Fix search input color
    * Disable earmark smartypants option

## v0.19.1

  * Enhancements
    * Update CSS styles
    * Remove sourcemaps from package

## v0.19.0

This release requires Elixir v1.7 and later. For earlier Elixir versions, use ExDoc ~> 0.18.0.

  * Enhancements
    * Do not select "iex>" when selecting code samples
    * Use makeup to perform ELixir's syntax highlighting (other languages still use highlight.js)
    * Use `[rel="noopener"]` on external links
    * Link directly to page if sidebar item has no subitems
    * Autolink Kernel and Kernel functions and special forms with shorthands (for example, only `is_atom/1` is necessary)
    * Trim EEx contents to reduce HTML size
    * Allow apps to be excluded from umbrella app docs

  * Bug fixes
    * Exclude types with `@typedoc false` from the docs
    * Make sure autolink considers the longest matching dependency name in case of shared prefixes

## v0.18.3

  * Bug fix
    * Fix formatting of typespecs causing errors
    * Update jQuery
    * Properly remove underscore from typespec links

## v0.18.2

  * Enhancements
    * Improve documentation pages for printing
    * Autolink Kernel, Kernel.SpecialForms, and built-in types
    * Annotate opaque types
    * Add vertical-align:top to tables
    * Allow module-function-arity references in links
    * Remove underscore from view source link
    * Run code formatter on typespecs (if one is available)
    * Make night mode switch link more obvious

## v0.18.1

  * Bug fixes
    * Include missing formatter files

## v0.18.0

  * Enhancements
    * No longer strip empty parens from types
    * Provide more extension point for markdown processors
    * Remove assets from priv since they are now embedded at compile time

  * Backwards incompatible changes
    * Remove built-in support for hoedown markdown processor
    * No longer add favicon when logo option is present (this was added in 0.17.0 but it was reported the logo almost never fits as a favicon)

## v0.17.1

  * Bug fixes
    * Fix broken search caused by outdated JavaScript files

## v0.17.0

  * Enhancements
    * Allow modules to be grouped on the sidebar with the `:groups_for_modules` option
    * Allow extras to be grouped on the sidebar with the `:groups_for_extras` option

  * Backwards incompatible changes
    * The previous `:group` option that could be specified for each entry in `:extras` is no longer supported
    * No longer add a specific section for "Protocols". If you would like to segregate the protocols in your application, use the new `:groups_for_modules` functionality

## v0.16.4

  * Enhancements
    * Generate favicon link if a logo is available

  * Bug fixes
    * Do not version epub filename as the doc directory is likely already versioned

## v0.16.3

  * Enhancements
    * Make sure its own search.html page and provide history
    * Generate source maps only if the `--debug` flag is given
    * Users can now add custom HTML before the closing head tag and the closing body tag
    * Highlight the target function/macro/type/callback when clicked

  * Bug fixes
    * Remove extra `term()` argument at start of macro spec
    * Add unencoded link target for functions with special chars to cope with different behaviour in browsers

## v0.16.2

  * Enhancements
    * Link `<h3>` headers as well
    * Add border to code tag
  * Bug fixes
    * Fix sidebar on mobile devices

## v0.16.1

  * Bug fixes
    * Fix hover icons coloring

## v0.16.0

  * Enhancements
    * Separate tasks into "Mix Tasks" in sidebar
    * Add types to the search results
    * Improve accessibility

  * Bug fixes
    * Strip nesting HTML tags in h2 headers
    * Remove the old search results after every new search attempt

## v0.15.1

  * Bug fixes
    * Improve project name wrapping on HTML
    * Properly set link in types with parameter
    * Fix ExDoc.CLI.main/2 to keep --source-ref on Elixir v1.4
    * Do not fail if localStorage is not available

## v0.15.0

  * Enhancements
    * Closing the search takes you to where you were in the previous page
    * Handle `__struct__/0` by displaying the struct instead
    * Warn when redirecting to a non-existent file
    * List both functions and macros under "Functions"
    * Automatically detect GitLab source URL patterns

  * Bug fixes
    * Break long specs into lines
    * Fix the initial state of the sidebar hamburger
    * Do not error when abstract code is missing
    * Properly link to erlang lib dirs

  * Backwards incompatible changes
    * No longer support Pandoc
    * Require Earmark 1.1

## v0.14.5

  * Enhancements
    * Allow ExDoc to work as an escript

## v0.14.4

  * Enhancements
    * Point to Elixir docs on hexdocs.pm
    * Many improvements to layout and styling of EPUB formatter
    * Support multiple formatters to be configured on `mix.exs`
    * Also digest `sidebar_items.js`
    * Force parentheses on type signature to remove ambiguity
    * Generate top-level docs for an umbrella project
    * Searching on mobile closes menu when the Enter key is hit

## v0.14.3

  * Enhancements
    * Support the `:assets` option that automatically copies all entries in the given directory to `doc/assets`
    * Remove numbering on Extras subheaders from sidebar
    * Pass file and line information to markdown formatters for better warnings
    * Allow extra pages to be grouped together under a given heading
    * Generate ids for default name/arity pairs so they can be linked (both remotely and locally)

  * Bug fixes
    * Fix autolink for functions containing `%`, `{`, `}` or uppercase characters in the name

## v0.14.2

  * Enhancements
    * Automatically generate documentations links to any of your dependencies (by default links to hexdocs.pm but allows the URL to be configured)
    * Allow documentation to be generated to Erlang modules

  * Bug fixes
    * Make sure "Top" is not included twice on pages

## v0.14.1

  * Bug fixes
    * Include "Top" link in pages with no headings
    * Include "Top" link in modules with no docs

## v0.14.0

  * Enhancements
    * Add support for the epub formatter
    * Support extraction from `<h2>` headers out of the settext format

  * Layout changes
    * Indent documentation inside the function/macro/type/callback header
    * Style types the same way as function/macro/callback and include a link to the source
    * Increase font-sizes in the sidebar and code snippets
    * Move the specs definition inside the function/macro/type/callback header and make better use of vertical space
    * Use a gradient on the sidebar to avoid sudden cut-off when scrolling the modules list
    * Fix the use of the back-button in some browsers
    * Allow the whole sidebar to be navigated without moving away from the current page. Expand (+) and collapse (-) buttons have been added to aid exploration
    * Numerically order pages/guides headers

## v0.13.2

  * Bug fixes
    * Avoid scrollbar from appearing on all code snippets

## v0.13.1

  * Enhancements
    * Autolink Elixir's stdlib modules and functions
    * Show callbacks in search results
    * Reduce size taken by font-sizes
    * Increase size for headings in the moduledoc

  * Bug fixes
    * Fix opened sidebar on small screens
    * Allow horizontal scrolling for code snippets on small screens

## v0.13.0

  * Bug fixes
    * Fix issue where docs would fail when being built on Erlang 19
    * Store templates in `priv` rather than in `lib`

  * Backwards incompatible changes
    * Require Elixir ~> v1.2

## v0.12.0

  * Enhancements
    * Remove warnings when running on Elixir v1.3
    * Support for `@optional_callbacks`
    * Improve styling for nested lists
    * Include earmark as a default dependency

  * Bug fixes
    * Fix many styling and performance front-end related bugs

## v0.11.5

  * Enhancements
    * Support canonical URLs

  * Bug fixes
    * Autolink now allows digits in function names
    * Sort specs by line to preserve ordering
    * Focus on content element on document ready
    * Remove ligature fix on Firefox and Safari as Google Fonts have been updated

## v0.11.4

  * Bug fixes
    * Fix ligature issues in recent browsers
    * HTML escape headers
    * Avoid warning on Elixir master (v1.3)

## v0.11.3

  * Bug fixes
    * Fix a regression where the sidebar wouldn't stick on small screens

## v0.11.2

  * Enhancements
    * Include night mode for docs
    * Take advantage of extra space on large screens by widening sidebar

  * Bug fixes
    * Do not attempt to retrieve docs from Erlang modules

## v0.11.1

  * Bug fixes
    * Include callbacks even if a module defines a struct

## v0.11.0

  * Enhancements
    * From now on it's possible to set the title in the sidebar area for
      additional content, *default:* "Pages"
    * Set the path and title of each additional page in `mix.exs` file
    * Use the first `h1` as menu title if title is not configured
    * Include the project name as part of the header in small devices

  * Bug fixes
    * Increase the visual separation between functions
    * Remove the `extra-` prefix for the additional documentation files
    * Extra large images do not create an overflow in the content

## v0.10.0

  * Enhancements
    * Many improvements and bug fixes in new layout
    * Reduced build size
    * Overview has been renamed to API Reference
    * All extra content, including API Reference, has been moved to inside
      "Pages"
    * Extra files are now downcased and prefixed by `extra-`

## v0.9.0

  * Enhancements
    * Whole new clean, readable, usable, responsive layout
    * Support for adding logo to generated docs (must be 64x64 pixels)
    * Support for adding extra pages to generated docs
    * Improve formatting of typespecs and callbacks

  * Backwards incompatible changes
    * `--readme` option and `:readme` configuration have been removed. Use
      `:extras` in your `mix.exs` file or pass `--extra` / `-e` in the
      command-line (may be given multiple times)

## v0.8.4

  * Bug fixes
    * Generate `README.html` file instead of `readme.html` as in previous
      releases
    * Style fixes in the new layout

## v0.8.3

  * Bug fixes
    * Style fixes in the new layout

## v0.8.2

  * Enhancements
    * Uglify and minify JS and CSS code
    * Performance improvements when building sidebar
    * Redirect from index.html to proper page

  * Bug fixes
    * Style fixes in the new layout

## v0.8.1

  * Bug fixes
    * Style fixes in the new layout

## v0.8.0

  * Enhancements
    * New and responsive layout without frames

## v0.7.3

  * Bug fixes
    * Update [highlight.js][] with fixes some inlining issues
    * Require latest [Earmark][]

## v0.7.2

  * Bug fixes
    * Support Elixir master
    * Fix error reporting when modules are compiled without docs

## v0.7.1

  * Enhancements
    * Use `type=search` for search input
    * Update [highlight.js][] dependency
    * Properly tag code comments as coming from Elixir/IEx unless noted otherwise
    * Add support for hash redirection

## v0.7.0

  * Enhancements
    * Documentation is now generated at `doc` to follow OTP "standard"

## v0.6.2

  * Enhancements
    * Improvements to the document structure
    * Add syntax highlight

## v0.6.1

  * Enhancements
    * Autolink modules and functions in the README
    * Generate ids for callbacks starting with "c:"
    * Ensure group ordering is consistent: TYPES > FUNCTIONS > MACROS > CALLBACKS
    * Allow users to search by Module.function

## v0.6.0

  * Enhancements
    * Support Elixir v1.0.0-rc1

## v0.5.2

  * Bug fixes
    * Use proper ANSI escape sequence on Mix success messages

## v0.5.1

  * Enhancements
    * Support Elixir v0.15.0
    * Add support for [Earmark][] - no need for external processors

## v0.5.0

  * Enhancements
    * First public release
    * Support [pandoc][] and [devinus/markdown][markdown] as markdown processors

[pandoc]: http://pandoc.org/
[markdown]: https://github.com/devinus/markdown
[earmark]: https://github.com/pragdave/earmark
[highlight.js]: https://highlightjs.org/
