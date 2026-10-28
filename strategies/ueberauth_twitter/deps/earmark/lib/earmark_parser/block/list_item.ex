defmodule Earmark.Parser.Block.ListItem do
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
#  SPDX-License-Identifier: Apache-2.0
