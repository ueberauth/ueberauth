defmodule Earmark.Parser.Line do
  @moduledoc false
  alias Earmark.Parser.Line

  @type annotation :: any() | nil
  @type lnb :: integer()
  @type line :: String.t()
  @type indent :: integer()
  @type content :: String.t()
  @type ial :: any() | nil
  @type type :: String.t()
  @type level :: integer()
  @type delimiter :: String.t()
  @type language :: any()
  @type tag :: String.t()
  @type complete :: boolean()
  @type id :: any()
  @type url :: String.t() | URI.t()
  @type title :: String.t()
  @type bullet :: String.t()
  @type initial_indent :: integer()
  @type list_indent :: integer()

  defmodule Blank do
    @moduledoc false

    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, content: "")
  end

  defmodule Ruler do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            type: Line.type()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, type: "- or * or _")
  end

  defmodule Heading do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            ial: Line.ial(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            level: Line.level(),
            content: Line.content()
          }

    defstruct(
      annotation: nil,
      ial: nil,
      lnb: 0,
      line: "",
      indent: -1,
      level: 1,
      content: "inline text"
    )
  end

  defmodule BlockQuote do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            ial: Line.ial(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            content: Line.content()
          }
    defstruct(annotation: nil, ial: nil, lnb: 0, line: "", indent: -1, content: "text")
  end

  defmodule Indent do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            level: Line.level(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, level: 0, content: "text")
  end

  defmodule Fence do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            delimiter: Line.delimiter(),
            language: Line.language()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, delimiter: "~ or `", language: nil)
  end

  defmodule HtmlOpenTag do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            tag: Line.tag(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "", content: "")
  end

  defmodule HtmlCloseTag do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            tag: Line.tag()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "<... to eol")
  end

  defmodule HtmlComment do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            complete: Line.complete()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, complete: true)
  end

  defmodule HtmlOneLine do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            tag: Line.tag(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "", content: "")
  end

  defmodule IdDef do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            id: Line.id(),
            url: Line.url(),
            title: Line.title()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, id: nil, url: nil, title: nil)
  end

  defmodule FnDef do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            id: Line.id(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, id: nil, content: "text")
  end

  defmodule ListItem do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            ial: Line.ial(),
            lnb: Line.lnb(),
            type: Line.type(),
            line: Line.line(),
            indent: Line.indent(),
            bullet: Line.bullet(),
            content: Line.content(),
            initial_indent: Line.initial_indent(),
            list_indent: Line.list_indent()
          }

    defstruct(
      annotation: nil,
      ial: nil,
      lnb: 0,
      type: :ul,
      line: "",
      indent: -1,
      bullet: "* or -",
      content: "text",
      initial_indent: 0,
      list_indent: 0
    )
  end

  defmodule SetextUnderlineHeading do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            level: Line.level()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, level: 1)
  end

  defmodule TableLine do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            content: Line.content(),
            columns: integer(),
            is_header: boolean(),
            needs_header: boolean()
          }

    defstruct(
      annotation: nil,
      lnb: 0,
      line: "",
      indent: -1,
      content: "",
      columns: 0,
      is_header: false,
      needs_header: false
    )
  end

  defmodule Ial do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            ial: Line.ial(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            attrs: String.t(),
            verbatim: String.t()
          }

    defstruct(annotation: nil, ial: nil, lnb: 0, line: "", indent: -1, attrs: "", verbatim: "")
  end

  defmodule Text do
    @moduledoc false
    @type t :: %__MODULE__{
            annotation: Line.annotation(),
            lnb: Line.lnb(),
            line: Line.line(),
            indent: Line.indent(),
            content: Line.content()
          }

    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, content: "")
  end
end

# SPDX-License-Identifier: Apache-2.0
