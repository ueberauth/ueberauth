defmodule Makeup.Styles.HTML.Style do
  @moduledoc """
  The style struct.
  """

  defstruct long_name: "",
            short_name: "",
            background_color: "#ffffff",
            highlight_color: "#ffffcc",
            styles: []

  alias Makeup.Styles.HTML.TokenStyle
  alias Makeup.Token.Utils

  defp handle_inheritance(style_map) do
    # Handles insheritance between styles.
    # This is automatic in Pygments' design, because they use class inheritance for tokens.
    # We don't have class inheritance in elixir, so we must have something else.
    # Here, we use a manually build hierarchy to fake inheritance.
    #
    # In any case, the goal is to have flat tokens at runtime.
    # This function is only called at compile time.
    Enum.reduce(Utils.precedence(), style_map, fn {parent_key, child_keys}, style_map ->
      parent_style = style_map[parent_key]

      Enum.reduce(child_keys, style_map, fn child_key, style_map ->
        child_style = style_map[child_key]

        Map.put(
          style_map,
          child_key,
          Map.merge(
            parent_style,
            child_style,
            fn _k, v1, v2 -> v2 || v1 end
          )
        )
      end)
    end)
  end

  require EEx

  EEx.function_from_string(
    :defp,
    :render_css,
    """
    .<%= highlight_class %> .hll {background-color: <%= highlight_color %>}
    .<%= highlight_class %> {\
    <%= if token_text.color do %>color: <%= token_text.color %>; <% end %>\
    <%= if token_text.font_style do %>font-style: <%= token_text.font_style %>; <% end %>\
    <%= if token_text.font_weight do %>font-weight: <%= token_text.font_weight %>; <% end %>\
    <%= if token_text.border do %>border: <%= token_text.border %>; <% end %>\
    <%= if token_text.text_decoration do %>text-decoration: <%= token_text.text_decoration %>; <% end %>\
    <%= if background_color do %>background-color: <%= background_color %><% end %>}\
    .<%= highlight_class %> .unselectable {
      -webkit-touch-callout: none;
      -webkit-user-select: none;
      -khtml-user-select: none;
      -moz-user-select: none;
      -ms-user-select: none;
      user-select: none;
    }
    <%= for {css_class, token_style, token_type} <- styles do %>
    .<%= highlight_class %> .<%= css_class %> {\
    <%= if token_style.color do %>color: <%= token_style.color %>; <% end %>\
    <%= if token_style.font_style do %>font-style: <%= token_style.font_style %>; <% end %>\
    <%= if token_style.font_weight do %>font-weight: <%= token_style.font_weight %>; <% end %>\
    <%= if token_style.border do %>border: <%= token_style.border %>; <% end %>\
    <%= if token_style.text_decoration do %>text-decoration: <%= token_style.text_decoration %>; <% end %>\
    <%= if token_style.background_color do %>background-color: <%= token_style.background_color %>; <% end %>\
    } /* :<%= Atom.to_string(token_type) %> */\
    <% end %>
    """,
    [:highlight_class, :highlight_color, :background_color, :token_text, :styles]
  )

  @doc """
  Generate a stylesheet for a style.
  """
  def stylesheet(style, css_class \\ "highlight") do
    token_styles =
      style.styles
      |> Map.delete(:text)
      |> Enum.into([])
      |> Enum.map(fn {token_type, token_style} ->
        css_class = Makeup.Token.Utils.css_class_for_token_type(token_type)
        {css_class, token_style, token_type}
      end)
      |> Enum.filter(fn {_, token_style, _} ->
        Makeup.Styles.HTML.TokenStyle.not_empty?(token_style)
      end)
      |> Enum.sort()

    token_text = style.styles[:text]

    render_css(
      css_class,
      style.highlight_color,
      style.background_color,
      token_text,
      token_styles
    )
  end

  @doc """
  Creates a new style.

  Takes care of unspecified token types and inheritance.
  Writes and caches a CSS stylesheet for the style.
  """
  def make_style(options \\ []) do
    short_name = Keyword.fetch!(options, :short_name)
    long_name = Keyword.fetch!(options, :long_name)
    background_color = Keyword.fetch!(options, :background_color)
    highlight_color = Keyword.fetch!(options, :highlight_color)
    incomplete_style_map = Keyword.fetch!(options, :styles)

    complete_style_map =
      Utils.standard_token_types()
      |> Enum.map(fn k -> {k, ""} end)
      |> Enum.into(%{})
      |> Map.merge(incomplete_style_map)
      |> Enum.map(fn {k, v} -> {k, TokenStyle.from_string(v)} end)
      |> Enum.into(%{})
      |> handle_inheritance

    %__MODULE__{
      long_name: long_name,
      short_name: short_name,
      background_color: background_color,
      highlight_color: highlight_color,
      styles: complete_style_map
    }
  end
end
