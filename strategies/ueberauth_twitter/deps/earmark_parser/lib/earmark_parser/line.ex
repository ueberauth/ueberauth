defmodule EarmarkParser.Line do
  @moduledoc false

  @type t ::
          %__MODULE__.Blank{}
          | %__MODULE__.Ruler{}
          | %__MODULE__.Heading{}
          | %__MODULE__.BlockQuote{}
          | %__MODULE__.Indent{}
          | %__MODULE__.Fence{}
          | %__MODULE__.HtmlOpenTag{}
          | %__MODULE__.HtmlCloseTag{}
          | %__MODULE__.HtmlComment{}
          | %__MODULE__.HtmlOneLine{}
          | %__MODULE__.IdDef{}
          | %__MODULE__.FnDef{}
          | %__MODULE__.ListItem{}
          | %__MODULE__.SetextUnderlineHeading{}
          | %__MODULE__.TableLine{}
          | %__MODULE__.Ial{}
          | %__MODULE__.Text{}

  defmodule Blank do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, content: "")
  end

  defmodule Ruler do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, type: "- or * or _")
  end

  defmodule Heading do
    @moduledoc false
    defstruct(annotation: nil, ial: nil, lnb: 0, line: "", indent: -1, level: 1, content: "inline text")
  end

  defmodule BlockQuote do
    @moduledoc false
    defstruct(annotation: nil, ial: nil, lnb: 0, line: "", indent: -1, content: "text")
  end

  defmodule Indent do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, level: 0, content: "text")
  end

  defmodule Fence do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, delimiter: "~ or `", language: nil)
  end

  defmodule HtmlOpenTag do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "", content: "")
  end

  defmodule HtmlCloseTag do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "<... to eol")
  end

  defmodule HtmlComment do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, complete: true)
  end

  defmodule HtmlOneLine do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, tag: "", content: "")
  end

  defmodule IdDef do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, id: nil, url: nil, title: nil)
  end

  defmodule FnDef do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, id: nil, content: "text")
  end

  defmodule ListItem do
    @moduledoc false
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

    @type natural :: non_neg_integer()

    @type t :: %__MODULE__{
            annotation: nil | String.t(),
            ial: nil | String.t(),
            lnb: natural,
            type: :ul | :ol,
            line: String.t(),
            indent: natural,
            bullet: String.t(),
            content: String.t(),
            initial_indent: natural,
            list_indent: natural
          }
  end

  defmodule SetextUnderlineHeading do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, level: 1)
  end

  defmodule TableLine do
    @moduledoc false
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
    defstruct(annotation: nil, ial: nil, lnb: 0, line: "", indent: -1, attrs: "", verbatim: "")
  end

  defmodule Text do
    @moduledoc false
    defstruct(annotation: nil, lnb: 0, line: "", indent: -1, content: "")
  end
end

# SPDX-License-Identifier: Apache-2.0
