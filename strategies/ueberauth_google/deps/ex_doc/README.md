# ExDoc

[![Build Status](https://github.com/elixir-lang/ex_doc/workflows/CI/badge.svg)](https://github.com/elixir-lang/ex_doc/actions?query=workflow%3A%22CI%22)

ExDoc is a tool to generate documentation for Erlang and Elixir projects. To see an example, [you can access Elixir's official docs](https://hexdocs.pm/elixir/).

## Features

ExDoc ships with many features:

  * Automatically generates offline-accessible HTML, Markdown (including `llms.txt`), and EPUB documents from your API documentation.
  * When hosted, ExDoc relies on browser's page transitions for better UX, caching, and enhanced accessibility.
  * Responsive design, covering phones and tablets.
  * Support for custom pages, guides, livebooks and cheatsheets.
  * Support for custom grouping of modules, functions, and pages in the sidebar.
  * Customizable logo and favicon.
  * A direct link back to the source code for every documented entity.
  * Full-text search.
  * Keyboard shortcuts. (Press `?` to show help.)
  * Quick-search with autocompletion support. (`s` keyboard shortcut.)
  * Go-to shortcut with auto-complete to take the reader to any HexDocs package documentation. (`g` keyboard shortcut.)
  * Support for night mode, activated according to the browser preference.
  * Tooltips for links to modules and functions, both for the current project and other projects.
  * Version dropdown and "Go to latest" notifications, automatically configured when hosted on HexDocs.

## Usage

You can use ExDoc with Mix (recommended for Elixir projects), with Rebar (recommended for Erlang projects), or via the command line.

<!-- tabs-open -->

### Mix

ExDoc requires Elixir v1.15 or later. Then add ExDoc as a dependency:

```elixir
def deps do
  [
    {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
  ]
end
```

Then run `mix deps.get`.

> #### Erlang development environment {: .warning}
>
> Some Operating System distributions split Erlang into multiple packages, and at least one ExDoc dependency (`earmark_parser`) requires the Erlang development environment. If you see a message like "/usr/lib/erlang/lib/parsetools-2.3.1/include/yeccpre.hrl: no such file or directory", it means you lack this environment. For instance, on the Debian operating system and its derivatives, you need to `apt install erlang-dev`.

ExDoc will automatically pull in information from your projects, such as the application and version. However, you may want to set `:name`, `:source_url` and `:homepage_url` in order to have nicer output from ExDoc:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0-dev",
    deps: deps(),

    # Docs
    name: "MyApp",
    source_url: "https://github.com/USER/PROJECT",
    homepage_url: "http://YOUR_PROJECT_HOMEPAGE",
    docs: &docs/0
  ]
end

defp docs do
  [
    main: "readme", # can be changed to a module name, if you prefer
    logo: "path/to/logo.png",
    extras: ["README.md"]
  ]
end
```

Now you are ready to generate your project documentation with `mix docs`. To see all options available, run `mix help docs`.

To learn about how to document your projects, see [Elixir's writing documentation page](https://hexdocs.pm/elixir/writing-documentation.html).

### Rebar3

From Erlang/OTP 24+, you can use ExDoc to render your Erlang documentation written with EDoc. See [`rebar3_ex_doc`](https://github.com/starbelly/rebar3_ex_doc/) for more information.

### CLI

You can use ExDoc via the command line.

1. Install ExDoc as an escript:

   ```bash
   $ mix escript.install hex ex_doc
   ```

2. Now you are ready to use it in your projects. Move into your project directory and make sure it's compiled:

   ```bash
   $ cd PATH_TO_YOUR_PROJECT
   $ mix compile
   ```

3. Invoke the `ex_doc` executable from your project:

   ```bash
   $ ex_doc "PROJECT_NAME" "PROJECT_VERSION" _build/dev/lib/project/ebin -m "PROJECT_MODULE" -u "https://github.com/GITHUB_USER/GITHUB_REPO" -l path/to/logo.png
   ```

   Examples of appropriate values:

   ```plain
   PROJECT_NAME    => Ecto
   PROJECT_VERSION => 0.1.0
   PROJECT_MODULE  => Ecto (the main module provided by the library)
   GITHUB_USER     => elixir-ecto
   GITHUB_REPO     => ecto
   ```

It is also possible to specify multiple `ebin` directories in the case of _umbrella_ projects:

   ```bash
   $ ex_doc "PROJECT_NAME" "PROJECT_VERSION" _build/dev/lib/app1/ebin _build/dev/lib/app2/ebin -m "PROJECT_MODULE" -u "https://github.com/GITHUB_USER/GITHUB_REPO" -l path/to/logo.png
   ```

If multiple `ebin` directories are specified, modules are grouped by application by default. It is possible to override this behaviour by providing a custom `groups_per_modules` option.

You can specify a config file via the `--config` option, both Elixir and Erlang formats are supported. Invoke `ex_doc` without arguments to learn more.

<!-- tabs-close -->

## Syntax highlighting

ExDoc uses [the makeup project](https://github.com/elixir-makeup/makeup) for syntax highlighting. By default, highlighters for Erlang and Elixir are included. To syntax-highlight other languages, simply add the equivalent `makeup_LANGUAGE` package to your `mix.exs`/`rebar.config` file. For example, for HTML support you would add:

<!-- tabs-open -->

### Elixir (Mix)

```elixir
{:makeup_html, ">= 0.0.0", only: :dev, runtime: false}
```

### Erlang (Rebar3)

```erlang
{makeup_html, "0.1.1"}
```

<!-- tabs-close -->

You can find all supported languages under [the Makeup organization on GitHub](https://github.com/elixir-makeup) and view them at [Makeup's website](https://elixir-makeup.github.io/makeup_demo/).

## Additional pages

You can publish additional pages in your project documentation by configuring them as `:extras`. The following formats and extensions are supported:

  * Markdown (`.md` extension) - useful for general long-term text. [Learn more](https://daringfireball.net/projects/markdown/syntax).

  * Cheatsheets (`.cheatmd` extension) - useful for discovery and quick reference. [Learn more](https://hexdocs.pm/ex_doc/cheatsheet.html).

  * Livebooks (`.livemd` extension) - useful for tutorials, interactive examples, and deep dives. [Learn more](https://livebook.dev/).

For example, you can set your `:extras` to:

<!-- tabs-open -->

### Elixir

```elixir
extras: ["README.md", "LICENSE", "tutorial.livemd", "cheatsheet.cheatmd"]
```

Run `mix help docs` for more information on configuration.

### Erlang

```elixir
{extras, [<<"README.md">>, <<"cheatsheet.cheatmd">>]}.
```

<!-- tabs-close -->

## Metadata

ExDoc supports metadata keys in your documentation.

<!-- tabs-open -->

### Elixir

In Elixir, you can add metadata to modules and functions.

For a module, use `@moduledoc`, which is equivalent to adding the annotation to everything inside the module (functions, macros, callbacks, types):

```elixir
@moduledoc since: "1.10.0"
```

For a function, use `@doc`:

```elixir
@doc since: "1.13.1"
```

### Erlang

In Erlang's EDoc:

```erlang
%% @since 0.1.0
```

<!-- tabs-close -->

The following metadata is available for both modules and functions:

  * `deprecated` (binary) - marks a module/function as deprecated, with the given string as the reason.
  * `since` (binary) - declares a module/function available from a particular version.

The following metadata is available for modules:

  * `tags` (list of atoms) - tags to be added as module annotations. (Not supported by EDoc.)

## Auto-linking

ExDoc for Elixir and Erlang will automatically generate links across modules and functions if you enclose them in backticks.

<!-- tabs-open -->

### Elixir

ExDoc will automatically link modules, functions, types or callbacks defined in your project and its dependencies (including Erlang and Elixir). ExDoc will automatically link to the dependency's documentation at [hexdocs.pm](https://hexdocs.pm/). The link can be configured by setting `docs: [deps: [my_dep: "https://path/to/docs/"]]` in your `mix.exs`.

ExDoc supports linking to modules (`` `MyModule` `` and `` `m:MyModule` ``), functions (`` `MyModule.function/1` ``), types (`` `t:MyModule.type/2` ``) and callbacks (`` `c:MyModule.callback/3` ``). If you want to link a function, type or callback in the current module, you may skip the module name, for example: `` `function/1` ``. Similarly, you can automatically link to Erlang modules (`` `m::my_module` ``), functions (`` `:my_module.function/1` ``), types (`` `t::my_module.type/2` ``) and callbacks (`` `c::my_module.callback/3` ``) (since Erlang modules in Elixir start with `:`, note the double colon in some cases).

You can also use custom text, such as `` [custom text](`MyModule.function/1`) ``. Link to extra pages using the syntax `` [Up and running](Up and running.md) ``. The final link will be automatically converted to `up-and-running.html`.

Link to extra pages in another application using the syntax `` [Writing Documentation](`e:elixir:writing-documentation.html`) ``, skipping the directory in which the page is. The final link will be automatically converted to `https://hexdocs.pm/elixir/writing-documentation.html`.

It is also possible to place anchors after the module name and extra pages. For example:

  * `` `m:Keyword#module-duplicate-keys-and-ordering` `` will create a link to `https://hexdocs.pm/elixir/Keyword.html#module-duplicate-keys-and-ordering`

  * `` `e:elixir:syntax-reference.md#expressions` `` will create a link to `https://hexdocs.pm/elixir/syntax-reference.html#expressions`

### Erlang

ExDoc will automatically link modules, functions, types or callbacks defined in your project and its dependencies (including Erlang and Elixir). ExDoc will automatically link to it at the dependency's documentation at [hexdocs.pm](https://hexdocs.pm/). The link can be configured by setting `docs: [deps: [my_dep: "https://path/to/docs/"]]` in your `mix.exs`. The link can be configured by setting `{docs, [{deps,  [{my_dep, "https://path/to/docs/"}]}]}` in your `rebar3.config`.

ExDoc supports linking to modules (`` `m:my_module` ``), functions (`` `my_module:function/1` ``), types (`` `t:my_module:type/2` ``) and callbacks (`` `c:my_module:callback/3` ``). If you want to link a function, type or callback in the current module, you may skip the module name; e.g.: `` `function/1` ``.

You can also use custom text, such as `` [custom text](`my_module:function/1`) ``. This also allows you to refer to Erlang/OTP modules: `` [The array module](`array`) `` (note that when a module is given as the link target, it is not necessary nor possible to use the `m:` prefix).

Link to extra pages using the syntax `` [Up and running](Up and running.md) ``. The final link will be automatically converted to `up-and-running.html`.

Link to extra pages in another application using the syntax `` [Using unicode](`e:stdlib:unicode_usage.html`) ``, skipping the directory in which the page is. The final link will be automatically converted to `https://hexdocs.pm/elixir/writing-documentation.html`.

It is also possible to place anchors after the module name and extra pages. For example:

  * `` `m:argparse#quick-start` `` will create a link to `https://erlang.org/doc/man/argparse#quick-start`

  * `` `e:stdlib:unicode-usage.md#what-unicode-is` `` will create a link to `https://erlang.org/doc/apps/stdlib/unicode-usage.html#what-unicode-is`

<!-- tabs-close -->

## Admonition blocks

You may want to draw attention to certain statements by taking them out of the content's flow and labeling them with a priority. Such statements are called admonitions. (They are also known as asides or callouts.) An admonition block is rendered based on the assigned label or class. ExDoc supports `warning`, `error`, `info`, `tip` and `neutral` tags, on header levels `h3` and `h4`.

The syntax is as follows:

```markdown
> #### Error {: .error}
>
> This syntax will render an error block
```

The result for the previous syntax is:

> #### Error {: .error}
>
> This syntax will render an error block

For example, if you change the class name to `neutral`, you get the same admonition block in neutral style:

> #### Neutral {: .neutral}
>
> This syntax will render a neutral block

## Tabsets

Where only one section of content of a series is likely to apply to the reader, you may wish to define a set of tabs.

This example contains code blocks, separating them into tabs based on language:

<!-- tabs-open -->

### Elixir

```elixir
IO.puts "Hello, world!"
```

### Erlang

```erlang
io:fwrite("Hello, world!\n").
```

<!-- tabs-close -->

Tabbed content must be defined between `<!-- tabs-open -->` and `<!-- tabs-close -->` HTML comments. Each `h3` heading results in a new tab panel, with its text setting the tab button label.

Here is the above example's source:

````markdown
<!-- tabs-open -->

### Elixir

```elixir
IO.puts "Hello, world!"
```

### Erlang

```erlang
io:fwrite("Hello, world!\n").
```

<!-- tabs-close -->
````

## Extensions

ExDoc renders Markdown content for you, but you can extend it to render complex objects on the page using JavaScript. To inject custom JavaScript into every page, add this to your configuration:

```elixir
docs: [
  # ...
  before_closing_head_tag: &before_closing_head_tag/1,
  before_closing_body_tag: &before_closing_body_tag/1
]

# ...

defp before_closing_head_tag(:html) do
  """
  <!-- HTML injected at the end of the <head> element -->
  """
end

defp before_closing_head_tag(:epub), do: ""

defp before_closing_body_tag(:html) do
  """
  <!-- HTML injected at the end of the <body> element -->
  """
end

defp before_closing_body_tag(:epub), do: ""
```

Besides an anonymous function, you can also pass a `module-function-args` tuple. It will call the given module and function, with the format prefixed to the arguments:

```elixir
docs: [
  # ...
  before_closing_head_tag: {MyModule, :before_closing_head_tag, []},
  before_closing_body_tag: {MyModule, :before_closing_body_tag, []}
]
```

Or you can pass a map where the key is the format:

```elixir
docs: [
  # ...
  before_closing_head_tag: %{html: "...", epub: "..."},
  before_closing_body_tag: %{html: "...", epub: "..."}
]
```

On the JavaScript side, ExDoc emits the `"exdoc:loaded"` event. This event may be called multiple times, as you navigate across pages, so initialization that should happen only once must be conditional. We recommend external scripts to use `defer`, not `async`, as shown in the examples below.

### Rendering Math

If you write TeX-style math in your Markdown, such as `$\sum_{i}^{N} x_i$`, it ends up as raw text on the generated pages. To render expressions, we recommend using [KaTeX](https://katex.org/), a JavaScript library that turns expressions into graphics. To load and trigger KaTeX on every documentation page, we can insert the following HTML:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.4/dist/katex.min.css" integrity="sha384-vKruj+a13U8yHIkAyGgK1J3ArTLzrFGBbBc0tDp4ad/EyewESeXE/Iv67Aj8gKZ0" crossorigin="anonymous">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.4/dist/katex.min.js" integrity="sha384-PwRUT/YqbnEjkZO0zZxNqcxACrXe+j766U2amXcgMg5457rve2Y7I6ZJSm2A0mS4" crossorigin="anonymous"></script>

<link href="https://cdn.jsdelivr.net/npm/katex-copytex@1.0.2/dist/katex-copytex.min.css" rel="stylesheet" type="text/css">
<script defer src="https://cdn.jsdelivr.net/npm/katex-copytex@1.0.2/dist/katex-copytex.min.js" crossorigin="anonymous"></script>

<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.4/dist/contrib/auto-render.min.js" integrity="sha384-+VBxd3r6XgURycqtZ117nYw44OOcIax56Z4dCRWbxyPt0Koah1uHoK0o4+/RRE05" crossorigin="anonymous"></script>

<script>
  window.addEventListener("exdoc:loaded", () => {
    renderMathInElement(document.body, {
      delimiters: [
        {left: '$$', right: '$$', display: true},
        {left: '$', right: '$', display: false},
      ]
    })
  })
</script>
```

For more details and configuration options, see the [KaTeX Auto-render Extension](https://katex.org/docs/autorender.html).

### Rendering Vega-Lite plots

Snippets are also objects you may want to render in a special manner. For example, assuming your Markdown includes Vega-Lite specification in `vega-lite` code snippets:

```html
<script defer src="https://cdn.jsdelivr.net/npm/vega@5.20.2"></script>
<script defer src="https://cdn.jsdelivr.net/npm/vega-lite@5.1.1"></script>
<script defer src="https://cdn.jsdelivr.net/npm/vega-embed@6.18.2"></script>
<script>
  window.addEventListener("exdoc:loaded", () => {
    for (const codeEl of document.querySelectorAll("pre code.vega-lite")) {
      try {
        const preEl = codeEl.parentElement;
        const spec = JSON.parse(codeEl.textContent);
        const plotEl = document.createElement("div");
        preEl.insertAdjacentElement("afterend", plotEl);
        vegaEmbed(plotEl, spec);
        preEl.remove();
      } catch (error) {
        console.log("Failed to render Vega-Lite plot: " + error)
      }
    }
  });
</script>
```

For more details and configuration options, see [vega/vega-embed](https://github.com/vega/vega-embed).

### Rendering Mermaid graphs

Similarly to the example above, if your Markdown includes Mermaid graph specification in `mermaid` code snippets:

```html
<script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
<script>
  let initialized = false;

  window.addEventListener("exdoc:loaded", () => {
    if (!initialized) {
      mermaid.initialize({
        startOnLoad: false,
        theme: document.body.className.includes("dark") ? "dark" : "default"
      });
      initialized = true;
    }

    let id = 0;
    for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
      const preEl = codeEl.parentElement;
      const graphDefinition = codeEl.textContent;
      const graphEl = document.createElement("div");
      const graphId = "mermaid-graph-" + id++;
      mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
        graphEl.innerHTML = svg;
        bindFunctions?.(graphEl);
        preEl.insertAdjacentElement("afterend", graphEl);
        preEl.remove();
      });
    }
  });
</script>
```

For more details and configuration options, see the [Mermaid usage docs](https://mermaid-js.github.io/mermaid/#/usage).

## Contributing

The easiest way to test changes to ExDoc is to locally rebuild the app and its own documentation:

  1. Run `mix setup` to install all dependencies
  2. Run `mix build` to generate the docs and open up the generated `doc/index.html`
  3. (optional) Run `erl -S httpd serve doc/` to serve the docs locally
  4. (optional) Run `npm run --prefix assets build:watch` if working on assets for automatic recompilation
  5. Run `mix lint` to check linting and formatting (and `mix fix` to automatically fix it)
  6. (important) Do not add the files in the `formatters/` directory to your commits, those will be handled by the maintainers

See the README in the `assets/` directory for more information on working on the assets.

## License

ExDoc source code is released under the Apache 2 License. The generated contents, however, are under different licenses based on projects used to help render HTML, including CSS, JS, and other assets.

Any documentation generated by ExDoc, or any documentation generated by any "Derivative Works" (as specified in the Apache 2 License), must include a direct, readable, and visible link to the [ExDoc repository](https://github.com/elixir-lang/ex_doc) on each rendered material. For HTML pages, every single page is a rendered material. For PDF, EPUB and other ebook formats, the whole body of documentation is a rendered material.
