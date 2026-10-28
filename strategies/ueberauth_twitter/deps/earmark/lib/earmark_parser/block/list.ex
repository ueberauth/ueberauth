defmodule Earmark.Parser.Block.List do
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
#  SPDX-License-Identifier: Apache-2.0
