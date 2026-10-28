defmodule Makeup.Styles.HTML.TokenStyle do
  @moduledoc false

  defstruct font_style: nil,
            font_weight: nil,
            border: nil,
            text_decoration: nil,
            color: nil,
            background_color: nil,
            literal: nil

  @doc """
  A `TokenStyle` is considered empty if all its fields are `nil`.

  A CSS class for an empty `TokenStyle` is not rendered in the stylesheet.
  This saves a little space and makes the stylesheet more human-readable.
  """
  def empty?(style) do
    not not_empty?(style)
  end

  @doc """
  A `TokenStyle` is empty if at least a field is not `nil`.

  A CSS class for an empty `TokenStyle` is rendered in the stylesheet.
  """
  def not_empty?(style) do
    style |> Map.from_struct() |> Map.values() |> Enum.any?()
  end

  # Foreground color
  defp to_attr("#" <> _ = color), do: {:color, color}
  # Background color
  defp to_attr("bg:" <> color), do: {:background_color, color}
  # Border (can only specify border color)
  defp to_attr("border:" <> color), do: {:border, color}
  # Font weight (bold vs normal)
  defp to_attr("bold"), do: {:font_weight, "bold"}
  defp to_attr("nobold"), do: {:font_weight, "normal"}
  # Font style (italic vs oblique vs normal)
  defp to_attr("italic"), do: {:font_style, "italic"}
  defp to_attr("oblique"), do: {:font_style, "oblique"}
  defp to_attr("noitalic"), do: {:font_style, "normal"}
  # Text decoration (underline vs none)
  defp to_attr("underline"), do: {:text_decoration, "underline"}
  # Unrecognized commands:
  defp to_attr(other) do
    # Log the command
    IO.warn("unknown attribute #{inspect(other)}")
    false
  end

  @doc """
  Creates a `TokenStyle` from string description.

  The string description is highly optimized for the goal of being typed by a human.
  The following commands are recognized:

  * `~r/#[0-9a-f]+/` for foreround color
  * `~r/bg:#[0-9a-f]+/` for background color
  * `~r/border:#[0-9a-f]+/` for border color
  * `italic` for `font-style: italic`
  * `oblique` for `font-style: oblique`
  * `noitalic` for `font-style: normal`
  * `underline` for `font-style: underline`

  No other commands are currently recognized.
  """
  def from_string(str) do
    attrs =
      str
      |> String.split()
      |> Enum.map(&to_attr/1)
      |> Enum.filter(fn x -> x end)

    struct(__MODULE__, attrs)
  end
end
