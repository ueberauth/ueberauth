defmodule EarmarkParser.Block do
  @moduledoc false

  @type t ::
          %__MODULE__.BlockQuote{}
          | %__MODULE__.Code{}
          | %__MODULE__.FnDef{}
          | %__MODULE__.FnList{}
          | %__MODULE__.Heading{}
          | %__MODULE__.Html{}
          | %__MODULE__.HtmlComment{}
          | %__MODULE__.HtmlOneline{}
          | %__MODULE__.Ial{}
          | %__MODULE__.IdDef{}
          | %__MODULE__.ListItem{}
          | %__MODULE__.List{}
          | %__MODULE__.Para{}
          | %__MODULE__.Ruler{}
          | %__MODULE__.Table{}
          | %__MODULE__.Text{}

  defmodule BlockQuote do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, blocks: []
  end

  defmodule Code do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, lines: [], language: nil
  end

  defmodule FnDef do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, id: nil, number: nil, blocks: []
  end

  defmodule FnList do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: ".footnotes", blocks: []
  end

  defmodule Heading do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, content: nil, level: nil
  end

  defmodule HtmlComment do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, lines: []
  end

  defmodule HtmlOneline do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, html: ""
  end

  defmodule Html do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, html: [], tag: nil
  end

  defmodule Ial do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, content: nil, verbatim: ""
  end

  defmodule IdDef do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, id: nil, url: nil, title: nil
  end

  defmodule ListItem do
    @moduledoc false
    defstruct attrs: nil,
              blocks: [],
              bullet: "",
              lnb: 0,
              annotation: nil,
              loose?: false,
              spaced?: true,
              type: :ul
  end

  defmodule List do
    @moduledoc false

    defstruct annotation: nil,
              attrs: nil,
              blocks: [],
              lines: [],
              bullet: "-",
              indent: 0,
              lnb: 0,
              loose?: false,
              pending: {nil, 0},
              spaced?: false,
              start: "",
              type: :ul
  end

  defmodule Para do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, lines: []
  end

  defmodule Ruler do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, type: nil
  end

  defmodule Table do
    @moduledoc false
    defstruct lnb: 0, annotation: nil, attrs: nil, rows: [], header: nil, alignments: []

    def new_for_columns(n) do
      %__MODULE__{alignments: Elixir.List.duplicate(:left, n)}
    end
  end

  defmodule Text do
    @moduledoc false
    defstruct attrs: nil, lnb: 0, annotation: nil, line: ""
  end
end

#  SPDX-License-Identifier: Apache-2.0
