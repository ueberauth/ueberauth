defmodule Makeup.Styles.HTML.StyleMap do
  @moduledoc """
  This module contains all styles, and facilities to map style names (binaries or atoms) to styles.

  Style names are of the form `<name>_style`.
  """

  alias Makeup.Styles.HTML.Style

  # %% Start Pygments %%

  @abap_style Style.make_style(
                short_name: "abap",
                long_name: "Abap Style",
                background_color: "#ffffff",
                highlight_color: "#ffffcc",
                styles: %{
                  :error => "#F00",
                  :keyword => "#00f",
                  :name => "#000",
                  :string => "#5a2",
                  :number => "#3af",
                  :operator_word => "#00f",
                  :comment => "italic #888",
                  :comment_special => "#888"
                }
              )

  @doc """
  The *abap* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#abap).
  """
  def abap_style, do: @abap_style

  @algol_style Style.make_style(
                 short_name: "algol",
                 long_name: "Algol Style",
                 background_color: "#ffffff",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "border:#FF0000",
                   :keyword => "underline bold",
                   :keyword_declaration => "italic",
                   :name_builtin => "bold italic",
                   :name_builtin_pseudo => "bold italic",
                   :name_class => "bold italic #666",
                   :name_constant => "bold italic #666",
                   :name_function => "bold italic #666",
                   :name_namespace => "bold italic #666",
                   :name_variable => "bold italic #666",
                   :string => "italic #666",
                   :operator_word => "bold",
                   :comment => "italic #888",
                   :comment_preproc => "bold noitalic #888",
                   :comment_special => "bold noitalic #888"
                 }
               )

  @doc """
  The *algol* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#algol).
  """
  def algol_style, do: @algol_style

  @algol_nu_style Style.make_style(
                    short_name: "algol_nu",
                    long_name: "Algol_Nu Style",
                    background_color: "#ffffff",
                    highlight_color: "#ffffcc",
                    styles: %{
                      :error => "border:#FF0000",
                      :keyword => "bold",
                      :keyword_declaration => "italic",
                      :name_builtin => "bold italic",
                      :name_builtin_pseudo => "bold italic",
                      :name_class => "bold italic #666",
                      :name_constant => "bold italic #666",
                      :name_function => "bold italic #666",
                      :name_namespace => "bold italic #666",
                      :name_variable => "bold italic #666",
                      :string => "italic #666",
                      :operator_word => "bold",
                      :comment => "italic #888",
                      :comment_preproc => "bold noitalic #888",
                      :comment_special => "bold noitalic #888"
                    }
                  )

  @doc """
  The *algol_nu* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#algol_nu).
  """
  def algol_nu_style, do: @algol_nu_style

  @arduino_style Style.make_style(
                   short_name: "arduino",
                   long_name: "Arduino Style",
                   background_color: "#ffffff",
                   highlight_color: "#ffffcc",
                   styles: %{
                     :error => "#a61717",
                     :keyword => "#728E00",
                     :keyword_constant => "#00979D",
                     :keyword_pseudo => "#00979D",
                     :keyword_reserved => "#00979D",
                     :keyword_type => "#00979D",
                     :name => "#434f54",
                     :name_builtin => "#728E00",
                     :name_function => "#D35400",
                     :name_other => "#728E00",
                     :string => "#7F8C8D",
                     :number => "#8A7B52",
                     :operator => "#728E00",
                     :comment => "#95a5a6",
                     :comment_preproc => "#728E00"
                   }
                 )

  @doc """
  The *arduino* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#arduino).
  """
  def arduino_style, do: @arduino_style

  @autumn_style Style.make_style(
                  short_name: "autumn",
                  long_name: "Autumn Style",
                  background_color: "#ffffff",
                  highlight_color: "#ffffcc",
                  styles: %{
                    :error => "#F00 bg:#FAA",
                    :keyword => "#0000aa",
                    :keyword_type => "#00aaaa",
                    :name_attribute => "#1e90ff",
                    :name_builtin => "#00aaaa",
                    :name_class => "underline #00aa00",
                    :name_constant => "#aa0000",
                    :name_decorator => "#888888",
                    :name_entity => "bold #800",
                    :name_function => "#00aa00",
                    :name_namespace => "underline #00aaaa",
                    :name_tag => "bold #1e90ff",
                    :name_variable => "#aa0000",
                    :string => "#aa5500",
                    :string_regex => "#009999",
                    :string_symbol => "#0000aa",
                    :number => "#009999",
                    :operator_word => "#0000aa",
                    :comment => "italic #aaaaaa",
                    :comment_preproc => "noitalic #4c8317",
                    :comment_special => "italic #0000aa",
                    :generic_deleted => "#aa0000",
                    :generic_emph => "italic",
                    :generic_error => "#aa0000",
                    :generic_heading => "bold #000080",
                    :generic_inserted => "#00aa00",
                    :generic_output => "#888888",
                    :generic_prompt => "#555555",
                    :generic_strong => "bold",
                    :generic_subheading => "bold #800080",
                    :generic_traceback => "#aa0000"
                  }
                )

  @doc """
  The *autumn* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#autumn).
  """
  def autumn_style, do: @autumn_style

  @borland_style Style.make_style(
                   short_name: "borland",
                   long_name: "Borland Style",
                   background_color: "#ffffff",
                   highlight_color: "#ffffcc",
                   styles: %{
                     :error => "bg:#e3d2d2 #a61717",
                     :keyword => "bold #000080",
                     :name_attribute => "#FF0000",
                     :name_tag => "bold #000080",
                     :string => "#0000FF",
                     :string_char => "#800080",
                     :number => "#0000FF",
                     :operator_word => "bold",
                     :comment => "italic #008800",
                     :comment_preproc => "noitalic #008080",
                     :comment_special => "noitalic bold",
                     :generic_deleted => "bg:#ffdddd #000000",
                     :generic_emph => "italic",
                     :generic_error => "#aa0000",
                     :generic_heading => "#999999",
                     :generic_inserted => "bg:#ddffdd #000000",
                     :generic_output => "#888888",
                     :generic_prompt => "#555555",
                     :generic_strong => "bold",
                     :generic_subheading => "#aaaaaa",
                     :generic_traceback => "#aa0000"
                   }
                 )

  @doc """
  The *borland* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#borland).
  """
  def borland_style, do: @borland_style

  @bw_style Style.make_style(
              short_name: "bw",
              long_name: "BlackWhite Style",
              background_color: "#ffffff",
              highlight_color: "#ffffcc",
              styles: %{
                :error => "border:#FF0000",
                :keyword => "bold",
                :keyword_pseudo => "nobold",
                :keyword_type => "nobold",
                :name_class => "bold",
                :name_entity => "bold",
                :name_exception => "bold",
                :name_namespace => "bold",
                :name_tag => "bold",
                :string => "italic",
                :string_escape => "bold",
                :string_interpol => "bold",
                :operator_word => "bold",
                :comment => "italic",
                :comment_preproc => "noitalic",
                :generic_emph => "italic",
                :generic_heading => "bold",
                :generic_prompt => "bold",
                :generic_strong => "bold",
                :generic_subheading => "bold"
              }
            )

  @doc """
  The *bw* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#bw).
  """
  def bw_style, do: @bw_style

  @colorful_style Style.make_style(
                    short_name: "colorful",
                    long_name: "Colorful Style",
                    background_color: "#ffffff",
                    highlight_color: "#ffffcc",
                    styles: %{
                      :error => "#F00 bg:#FAA",
                      :keyword => "bold #080",
                      :keyword_pseudo => "#038",
                      :keyword_type => "#339",
                      :name_attribute => "#00C",
                      :name_builtin => "#007020",
                      :name_class => "bold #B06",
                      :name_constant => "bold #036",
                      :name_decorator => "bold #555",
                      :name_entity => "bold #800",
                      :name_exception => "bold #F00",
                      :name_function => "bold #06B",
                      :name_label => "bold #970",
                      :name_namespace => "bold #0e84b5",
                      :name_tag => "#070",
                      :name_variable => "#963",
                      :name_variable_class => "#369",
                      :name_variable_global => "bold #d70",
                      :name_variable_instance => "#33B",
                      :string => "bg:#fff0f0",
                      :string_char => "#04D bg:",
                      :string_doc => "#D42 bg:",
                      :string_escape => "bold #666",
                      :string_interpol => "bg:#eee",
                      :string_other => "#D20",
                      :string_regex => "bg:#fff0ff #000",
                      :string_symbol => "#A60 bg:",
                      :number => "bold #60E",
                      :number_float => "bold #60E",
                      :number_hex => "bold #058",
                      :number_integer => "bold #00D",
                      :number_oct => "bold #40E",
                      :operator => "#333",
                      :operator_word => "bold #000",
                      :comment => "#888",
                      :comment_preproc => "#579",
                      :comment_special => "bold #cc0000",
                      :generic_deleted => "#A00000",
                      :generic_emph => "italic",
                      :generic_error => "#FF0000",
                      :generic_heading => "bold #000080",
                      :generic_inserted => "#00A000",
                      :generic_output => "#888",
                      :generic_prompt => "bold #c65d09",
                      :generic_strong => "bold",
                      :generic_subheading => "bold #800080",
                      :generic_traceback => "#04D"
                    }
                  )

  @doc """
  The *colorful* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#colorful).
  """
  def colorful_style, do: @colorful_style

  @default_style Style.make_style(
                   short_name: "default",
                   long_name: "Default Style",
                   background_color: "#f8f8f8",
                   highlight_color: "#ffffcc",
                   styles: %{
                     :error => "border:#FF0000",
                     :keyword => "bold #008000",
                     :keyword_pseudo => "nobold",
                     :keyword_type => "nobold #B00040",
                     :name_attribute => "#7D9029",
                     :name_builtin => "#008000",
                     :name_class => "bold #0000FF",
                     :name_constant => "#880000",
                     :name_decorator => "#AA22FF",
                     :name_entity => "bold #999999",
                     :name_exception => "bold #D2413A",
                     :name_function => "#0000FF",
                     :name_label => "#A0A000",
                     :name_namespace => "bold #0000FF",
                     :name_tag => "bold #008000",
                     :name_variable => "#19177C",
                     :string => "#BA2121",
                     :string_doc => "italic",
                     :string_escape => "bold #BB6622",
                     :string_interpol => "bold #BB6688",
                     :string_other => "#008000",
                     :string_regex => "#BB6688",
                     :string_symbol => "#19177C",
                     :number => "#666666",
                     :operator => "#666666",
                     :operator_word => "bold #AA22FF",
                     :comment => "italic #408080",
                     :comment_preproc => "noitalic #BC7A00",
                     :generic_deleted => "#A00000",
                     :generic_emph => "italic",
                     :generic_error => "#FF0000",
                     :generic_heading => "bold #000080",
                     :generic_inserted => "#00A000",
                     :generic_output => "#888",
                     :generic_prompt => "bold #000080",
                     :generic_strong => "bold",
                     :generic_subheading => "bold #800080",
                     :generic_traceback => "#04D"
                   }
                 )

  @doc """
  The *default* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#default).
  """
  def default_style, do: @default_style

  @dracula_style Style.make_style(
    short_name: "dracula",
    long_name: "Dracula Style",
    background_color: "#282a36",
    highlight_color: "#44475A",
    styles: %{
      :comment_single => "#44475A",
      :keyword => "#FF92DF",
      :keyword_declaration => "#FF92DF",
      :keyword_namespace => "#FF92DF",
      :name => "#50FA7B",
      :name_attribute => "#BD93F9",
      :name_builtin_pseudo => "#44475A",
      :name_class => "#A4FFFF",
      :name_constant => "#BD93F9",
      :name_function => "#50FA7B",
      :operator => "#FF92DF",
      :punctuation => "#F8F8F2",
      :string => "#F1FA8C",
      :string_symbol => "#FFB86C",
    }
  )

  @doc """
  The *dracula* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#dracula).
  """
  def dracula_style, do: @dracula_style

  @emacs_style Style.make_style(
                 short_name: "emacs",
                 long_name: "Emacs Style",
                 background_color: "#f8f8f8",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "border:#FF0000",
                   :keyword => "bold #AA22FF",
                   :keyword_pseudo => "nobold",
                   :keyword_type => "bold #00BB00",
                   :name_attribute => "#BB4444",
                   :name_builtin => "#AA22FF",
                   :name_class => "#0000FF",
                   :name_constant => "#880000",
                   :name_decorator => "#AA22FF",
                   :name_entity => "bold #999999",
                   :name_exception => "bold #D2413A",
                   :name_function => "#00A000",
                   :name_label => "#A0A000",
                   :name_namespace => "bold #0000FF",
                   :name_tag => "bold #008000",
                   :name_variable => "#B8860B",
                   :string => "#BB4444",
                   :string_doc => "italic",
                   :string_escape => "bold #BB6622",
                   :string_interpol => "bold #BB6688",
                   :string_other => "#008000",
                   :string_regex => "#BB6688",
                   :string_symbol => "#B8860B",
                   :number => "#666666",
                   :operator => "#666666",
                   :operator_word => "bold #AA22FF",
                   :comment => "italic #008800",
                   :comment_preproc => "noitalic",
                   :comment_special => "noitalic bold",
                   :generic_deleted => "#A00000",
                   :generic_emph => "italic",
                   :generic_error => "#FF0000",
                   :generic_heading => "bold #000080",
                   :generic_inserted => "#00A000",
                   :generic_output => "#888",
                   :generic_prompt => "bold #000080",
                   :generic_strong => "bold",
                   :generic_subheading => "bold #800080",
                   :generic_traceback => "#04D"
                 }
               )

  @doc """
  The *emacs* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#emacs).
  """
  def emacs_style, do: @emacs_style

  @friendly_style Style.make_style(
                    short_name: "friendly",
                    long_name: "Friendly Style",
                    background_color: "#f0f0f0",
                    highlight_color: "#ffffcc",
                    styles: %{
                      :error => "border:#FF0000",
                      :keyword => "bold #007020",
                      :keyword_pseudo => "nobold",
                      :keyword_type => "nobold #902000",
                      :name_attribute => "#4070a0",
                      :name_builtin => "#007020",
                      :name_class => "bold #0e84b5",
                      :name_constant => "#60add5",
                      :name_decorator => "bold #555555",
                      :name_entity => "bold #d55537",
                      :name_exception => "#007020",
                      :name_function => "#06287e",
                      :name_label => "bold #002070",
                      :name_namespace => "bold #0e84b5",
                      :name_tag => "bold #062873",
                      :name_variable => "#bb60d5",
                      :string => "#4070a0",
                      :string_doc => "italic",
                      :string_escape => "bold #4070a0",
                      :string_interpol => "italic #70a0d0",
                      :string_other => "#c65d09",
                      :string_regex => "#235388",
                      :string_symbol => "#517918",
                      :number => "#40a070",
                      :operator => "#666666",
                      :operator_word => "bold #007020",
                      :comment => "italic #60a0b0",
                      :comment_preproc => "noitalic #007020",
                      :comment_special => "noitalic bg:#fff0f0",
                      :generic_deleted => "#A00000",
                      :generic_emph => "italic",
                      :generic_error => "#FF0000",
                      :generic_heading => "bold #000080",
                      :generic_inserted => "#00A000",
                      :generic_output => "#888",
                      :generic_prompt => "bold #c65d09",
                      :generic_strong => "bold",
                      :generic_subheading => "bold #800080",
                      :generic_traceback => "#04D"
                    }
                  )

  @doc """
  The *friendly* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#friendly).
  """
  def friendly_style, do: @friendly_style

  @fruity_style Style.make_style(
                  short_name: "fruity",
                  long_name: "Fruity Style",
                  background_color: "#111111",
                  highlight_color: "#333333",
                  styles: %{
                    :keyword => "#fb660a bold",
                    :keyword_pseudo => "nobold",
                    :keyword_type => "#cdcaa9 bold",
                    :name_attribute => "#ff0086 bold",
                    :name_constant => "#0086d2",
                    :name_function => "#ff0086 bold",
                    :name_tag => "#fb660a bold",
                    :name_variable => "#fb660a",
                    :string => "#0086d2",
                    :number => "#0086f7 bold",
                    :comment => "#008800 bg:#0f140f italic",
                    :comment_preproc => "#ff0007 bold",
                    :generic_heading => "#ffffff bold",
                    :generic_output => "#444444 bg:#222222",
                    :generic_subheading => "#ffffff bold"
                  }
                )

  @doc """
  The *fruity* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#fruity).
  """
  def fruity_style, do: @fruity_style

  @igor_style Style.make_style(
                short_name: "igor",
                long_name: "Igor Style",
                background_color: "#ffffff",
                highlight_color: "#ffffcc",
                styles: %{
                  :keyword => "#0000FF",
                  :name_class => "#007575",
                  :name_decorator => "#CC00A3",
                  :name_function => "#C34E00",
                  :string => "#009C00",
                  :comment => "italic #FF0000"
                }
              )

  @doc """
  The *igor* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#igor).
  """
  def igor_style, do: @igor_style

  @lovelace_style Style.make_style(
                    short_name: "lovelace",
                    long_name: "Lovelace Style",
                    background_color: "#ffffff",
                    highlight_color: "#ffffcc",
                    styles: %{
                      :error => "bg:#a848a8",
                      :keyword => "#2838b0",
                      :keyword_constant => "italic #444444",
                      :keyword_declaration => "italic",
                      :keyword_type => "italic",
                      :name_attribute => "#388038",
                      :name_builtin => "#388038",
                      :name_builtin_pseudo => "italic",
                      :name_class => "#287088",
                      :name_constant => "#b85820",
                      :name_decorator => "#287088",
                      :name_entity => "#709030",
                      :name_exception => "#908828",
                      :name_function => "#785840",
                      :name_function_magic => "#b85820",
                      :name_label => "#289870",
                      :name_namespace => "#289870",
                      :name_tag => "#2838b0",
                      :name_variable => "#b04040",
                      :name_variable_global => "#908828",
                      :name_variable_magic => "#b85820",
                      :string => "#b83838",
                      :string_affix => "#444444",
                      :string_char => "#a848a8",
                      :string_delimiter => "#b85820",
                      :string_doc => "italic #b85820",
                      :string_escape => "#709030",
                      :string_interpol => "underline",
                      :string_other => "#a848a8",
                      :string_regex => "#a848a8",
                      :number => "#444444",
                      :operator => "#666666",
                      :operator_word => "#a848a8",
                      :punctuation => "#888888",
                      :comment => "italic #888888",
                      :comment_hashbang => "#287088",
                      :comment_multiline => "#888888",
                      :comment_preproc => "noitalic #289870",
                      :generic_deleted => "#c02828",
                      :generic_emph => "italic",
                      :generic_error => "#c02828",
                      :generic_heading => "#666666",
                      :generic_inserted => "#388038",
                      :generic_output => "#666666",
                      :generic_prompt => "#444444",
                      :generic_strong => "bold",
                      :generic_subheading => "#444444",
                      :generic_traceback => "#2838b0"
                    }
                  )

  @doc """
  The *lovelace* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#lovelace).
  """
  def lovelace_style, do: @lovelace_style

  @manni_style Style.make_style(
                 short_name: "manni",
                 long_name: "Manni Style",
                 background_color: "#f0f3f3",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "bg:#FFAAAA #AA0000",
                   :keyword => "bold #006699",
                   :keyword_pseudo => "nobold",
                   :keyword_type => "#007788",
                   :name_attribute => "#330099",
                   :name_builtin => "#336666",
                   :name_class => "bold #00AA88",
                   :name_constant => "#336600",
                   :name_decorator => "#9999FF",
                   :name_entity => "bold #999999",
                   :name_exception => "bold #CC0000",
                   :name_function => "#CC00FF",
                   :name_label => "#9999FF",
                   :name_namespace => "bold #00CCFF",
                   :name_tag => "bold #330099",
                   :name_variable => "#003333",
                   :string => "#CC3300",
                   :string_doc => "italic",
                   :string_escape => "bold #CC3300",
                   :string_interpol => "#AA0000",
                   :string_other => "#CC3300",
                   :string_regex => "#33AAAA",
                   :string_symbol => "#FFCC33",
                   :number => "#FF6600",
                   :operator => "#555555",
                   :operator_word => "bold #000000",
                   :comment => "italic #0099FF",
                   :comment_preproc => "noitalic #009999",
                   :comment_special => "bold",
                   :generic_deleted => "border:#CC0000 bg:#FFCCCC",
                   :generic_emph => "italic",
                   :generic_error => "#FF0000",
                   :generic_heading => "bold #003300",
                   :generic_inserted => "border:#00CC00 bg:#CCFFCC",
                   :generic_output => "#AAAAAA",
                   :generic_prompt => "bold #000099",
                   :generic_strong => "bold",
                   :generic_subheading => "bold #003300",
                   :generic_traceback => "#99CC66"
                 }
               )

  @doc """
  The *manni* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#manni).
  """
  def manni_style, do: @manni_style

  @monokai_style Style.make_style(
                   short_name: "monokai",
                   long_name: "Monokai Style",
                   background_color: "#272822",
                   highlight_color: "#49483e",
                   styles: %{
                     :text => "#f8f8f2",
                     :error => "#960050 bg:#1e0010",
                     :keyword => "#66d9ef",
                     :keyword_namespace => "#f92672",
                     :name => "#f8f8f2",
                     :name_attribute => "#a6e22e",
                     :name_class => "#a6e22e",
                     :name_constant => "#66d9ef",
                     :name_decorator => "#a6e22e",
                     :name_exception => "#a6e22e",
                     :name_function => "#a6e22e",
                     :name_other => "#a6e22e",
                     :name_tag => "#f92672",
                     :literal => "#ae81ff",
                     :string => "#e6db74",
                     :string_escape => "#ae81ff",
                     :number => "#ae81ff",
                     :operator => "#f92672",
                     :punctuation => "#f8f8f2",
                     :comment => "#75715e",
                     :generic_deleted => "#f92672",
                     :generic_emph => "italic",
                     :generic_inserted => "#a6e22e",
                     :generic_strong => "bold",
                     :generic_subheading => "#75715e"
                   }
                 )

  @doc """
  The *monokai* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#monokai).
  """
  def monokai_style, do: @monokai_style

  @murphy_style Style.make_style(
                  short_name: "murphy",
                  long_name: "Murphy Style",
                  background_color: "#ffffff",
                  highlight_color: "#ffffcc",
                  styles: %{
                    :error => "#F00 bg:#FAA",
                    :keyword => "bold #289",
                    :keyword_pseudo => "#08f",
                    :keyword_type => "#66f",
                    :name_attribute => "#007",
                    :name_builtin => "#072",
                    :name_class => "bold #e9e",
                    :name_constant => "bold #5ed",
                    :name_decorator => "bold #555",
                    :name_entity => "#800",
                    :name_exception => "bold #F00",
                    :name_function => "bold #5ed",
                    :name_label => "bold #970",
                    :name_namespace => "bold #0e84b5",
                    :name_tag => "#070",
                    :name_variable => "#036",
                    :name_variable_class => "#ccf",
                    :name_variable_global => "#f84",
                    :name_variable_instance => "#aaf",
                    :string => "bg:#e0e0ff",
                    :string_char => "#88F bg:",
                    :string_doc => "#D42 bg:",
                    :string_escape => "bold #666",
                    :string_interpol => "bg:#eee",
                    :string_other => "#f88",
                    :string_regex => "bg:#e0e0ff #000",
                    :string_symbol => "#fc8 bg:",
                    :number => "bold #60E",
                    :number_float => "bold #60E",
                    :number_hex => "bold #058",
                    :number_integer => "bold #66f",
                    :number_oct => "bold #40E",
                    :operator => "#333",
                    :operator_word => "bold #000",
                    :comment => "#666 italic",
                    :comment_preproc => "#579 noitalic",
                    :comment_special => "#c00 bold",
                    :generic_deleted => "#A00000",
                    :generic_emph => "italic",
                    :generic_error => "#FF0000",
                    :generic_heading => "bold #000080",
                    :generic_inserted => "#00A000",
                    :generic_output => "#888",
                    :generic_prompt => "bold #c65d09",
                    :generic_strong => "bold",
                    :generic_subheading => "bold #800080",
                    :generic_traceback => "#04D"
                  }
                )

  @doc """
  The *murphy* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#murphy).
  """
  def murphy_style, do: @murphy_style

  @native_style Style.make_style(
                  short_name: "native",
                  long_name: "Native Style",
                  background_color: "#202020",
                  highlight_color: "#404040",
                  styles: %{
                    :error => "bg:#e3d2d2 #a61717",
                    :keyword => "bold #6ab825",
                    :keyword_pseudo => "nobold",
                    :name_attribute => "#bbbbbb",
                    :name_builtin => "#24909d",
                    :name_class => "underline #447fcf",
                    :name_constant => "#40ffff",
                    :name_decorator => "#ffa500",
                    :name_exception => "#bbbbbb",
                    :name_function => "#447fcf",
                    :name_namespace => "underline #447fcf",
                    :name_tag => "bold #6ab825",
                    :name_variable => "#40ffff",
                    :string => "#ed9d13",
                    :string_other => "#ffa500",
                    :number => "#3677a9",
                    :operator_word => "bold #6ab825",
                    :comment => "italic #999999",
                    :comment_preproc => "noitalic bold #cd2828",
                    :comment_special => "noitalic bold #e50808 bg:#520000",
                    :generic_deleted => "#d22323",
                    :generic_emph => "italic",
                    :generic_error => "#d22323",
                    :generic_heading => "bold #ffffff",
                    :generic_inserted => "#589819",
                    :generic_output => "#cccccc",
                    :generic_prompt => "#aaaaaa",
                    :generic_strong => "bold",
                    :generic_subheading => "underline #ffffff",
                    :generic_traceback => "#d22323"
                  }
                )

  @doc """
  The *native* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#native).
  """
  def native_style, do: @native_style

  @one_dark_style Style.make_style(
    short_name: "one_dark",
    long_name: "One Dark Style",
    background_color: "#282c34",
    highlight_color: "#31353f",
    styles: %{
      :punctuation => "#ABB2BF",
      :keyword => "#C678DD",
      :keyword_constant => "#E5C07B",
      :keyword_declaration => "#C678DD",
      :keyword_namespace => "#C678DD",
      :keyword_reserved => "#C678DD",
      :keyword_type => "#E5C07B",
      :name => "#C4CAD6",
      :name_attribute => "#E06C75",
      :name_builtin => "#E5C07B",
      :name_class => "#E06C75",
      :name_constant => "#61AFEF",
      :name_function => "bold #61AFEF",
      :name_function_magic => "bold #56B6C2",
      :name_other => "#E06C75",
      :name_tag => "#E06C75",
      :name_decorator => "#61AFEF",
      :string => "#98C379",
      :string_symbol => "#61AFEF",
      :number => "#D19A66",
      :operator => "#56B6C2",
      :comment => "#8C92A3"
    }
  )

  @doc """
  The *one_dark* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#one_dark).
  """
  def one_dark_style, do: @one_dark_style

  @paraiso_dark_style Style.make_style(
                        short_name: "paraiso_dark",
                        long_name: "ParaisoDark Style",
                        background_color: "#2f1e2e",
                        highlight_color: "#4f424c",
                        styles: %{
                          :text => "#e7e9db",
                          :error => "#ef6155",
                          :keyword => "#815ba4",
                          :keyword_namespace => "#5bc4bf",
                          :keyword_type => "#fec418",
                          :name => "#e7e9db",
                          :name_attribute => "#06b6ef",
                          :name_class => "#fec418",
                          :name_constant => "#ef6155",
                          :name_decorator => "#5bc4bf",
                          :name_exception => "#ef6155",
                          :name_function => "#06b6ef",
                          :name_namespace => "#fec418",
                          :name_other => "#06b6ef",
                          :name_tag => "#5bc4bf",
                          :name_variable => "#ef6155",
                          :literal => "#f99b15",
                          :string => "#48b685",
                          :string_char => "#e7e9db",
                          :string_doc => "#776e71",
                          :string_escape => "#f99b15",
                          :string_interpol => "#f99b15",
                          :number => "#f99b15",
                          :operator => "#5bc4bf",
                          :punctuation => "#e7e9db",
                          :comment => "#776e71",
                          :generic_deleted => "#ef6155",
                          :generic_emph => "italic",
                          :generic_heading => "bold #e7e9db",
                          :generic_inserted => "#48b685",
                          :generic_prompt => "bold #776e71",
                          :generic_strong => "bold",
                          :generic_subheading => "bold #5bc4bf"
                        }
                      )

  @doc """
  The *paraiso_dark* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#paraiso_dark).
  """
  def paraiso_dark_style, do: @paraiso_dark_style

  @paraiso_light_style Style.make_style(
                         short_name: "paraiso_light",
                         long_name: "ParaisoLight Style",
                         background_color: "#e7e9db",
                         highlight_color: "#a39e9b",
                         styles: %{
                           :text => "#2f1e2e",
                           :error => "#ef6155",
                           :keyword => "#815ba4",
                           :keyword_namespace => "#5bc4bf",
                           :keyword_type => "#fec418",
                           :name => "#2f1e2e",
                           :name_attribute => "#06b6ef",
                           :name_class => "#fec418",
                           :name_constant => "#ef6155",
                           :name_decorator => "#5bc4bf",
                           :name_exception => "#ef6155",
                           :name_function => "#06b6ef",
                           :name_namespace => "#fec418",
                           :name_other => "#06b6ef",
                           :name_tag => "#5bc4bf",
                           :name_variable => "#ef6155",
                           :literal => "#f99b15",
                           :string => "#48b685",
                           :string_char => "#2f1e2e",
                           :string_doc => "#8d8687",
                           :string_escape => "#f99b15",
                           :string_interpol => "#f99b15",
                           :number => "#f99b15",
                           :operator => "#5bc4bf",
                           :punctuation => "#2f1e2e",
                           :comment => "#8d8687",
                           :generic_deleted => "#ef6155",
                           :generic_emph => "italic",
                           :generic_heading => "bold #2f1e2e",
                           :generic_inserted => "#48b685",
                           :generic_prompt => "bold #8d8687",
                           :generic_strong => "bold",
                           :generic_subheading => "bold #5bc4bf"
                         }
                       )

  @doc """
  The *paraiso_light* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#paraiso_light).
  """
  def paraiso_light_style, do: @paraiso_light_style

  @pastie_style Style.make_style(
                  short_name: "pastie",
                  long_name: "Pastie Style",
                  background_color: "#ffffff",
                  highlight_color: "#ffffcc",
                  styles: %{
                    :error => "bg:#e3d2d2 #a61717",
                    :keyword => "bold #008800",
                    :keyword_pseudo => "nobold",
                    :keyword_type => "#888888",
                    :name_attribute => "#336699",
                    :name_builtin => "#003388",
                    :name_class => "bold #bb0066",
                    :name_constant => "bold #003366",
                    :name_decorator => "#555555",
                    :name_exception => "bold #bb0066",
                    :name_function => "bold #0066bb",
                    :name_property => "bold #336699",
                    :name_label => "italic #336699",
                    :name_namespace => "bold #bb0066",
                    :name_tag => "bold #bb0066",
                    :name_variable => "#336699",
                    :name_variable_class => "#336699",
                    :name_variable_global => "#dd7700",
                    :name_variable_instance => "#3333bb",
                    :string => "bg:#fff0f0 #dd2200",
                    :string_escape => "#0044dd",
                    :string_interpol => "#3333bb",
                    :string_other => "bg:#f0fff0 #22bb22",
                    :string_regex => "bg:#fff0ff #008800",
                    :string_symbol => "#aa6600",
                    :number => "bold #0000DD",
                    :operator_word => "#008800",
                    :comment => "#888888",
                    :comment_preproc => "bold #cc0000",
                    :comment_special => "bg:#fff0f0 bold #cc0000",
                    :generic_deleted => "bg:#ffdddd #000000",
                    :generic_emph => "italic",
                    :generic_error => "#aa0000",
                    :generic_heading => "#333",
                    :generic_inserted => "bg:#ddffdd #000000",
                    :generic_output => "#888888",
                    :generic_prompt => "#555555",
                    :generic_strong => "bold",
                    :generic_subheading => "#666",
                    :generic_traceback => "#aa0000"
                  }
                )

  @doc """
  The *pastie* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#pastie).
  """
  def pastie_style, do: @pastie_style

  @perldoc_style Style.make_style(
                   short_name: "perldoc",
                   long_name: "Perldoc Style",
                   background_color: "#eeeedd",
                   highlight_color: "#ffffcc",
                   styles: %{
                     :error => "bg:#e3d2d2 #a61717",
                     :keyword => "#8B008B bold",
                     :keyword_type => "#00688B",
                     :name_attribute => "#658b00",
                     :name_builtin => "#658b00",
                     :name_class => "#008b45 bold",
                     :name_constant => "#00688B",
                     :name_decorator => "#707a7c",
                     :name_exception => "#008b45 bold",
                     :name_function => "#008b45",
                     :name_namespace => "#008b45 underline",
                     :name_tag => "#8B008B bold",
                     :name_variable => "#00688B",
                     :string => "#CD5555",
                     :string_heredoc => "#1c7e71 italic",
                     :string_other => "#cb6c20",
                     :string_regex => "#1c7e71",
                     :number => "#B452CD",
                     :operator_word => "#8B008B",
                     :comment => "#228B22",
                     :comment_preproc => "#1e889b",
                     :comment_special => "#8B008B bold",
                     :generic_deleted => "#aa0000",
                     :generic_emph => "italic",
                     :generic_error => "#aa0000",
                     :generic_heading => "bold #000080",
                     :generic_inserted => "#00aa00",
                     :generic_output => "#888888",
                     :generic_prompt => "#555555",
                     :generic_strong => "bold",
                     :generic_subheading => "bold #800080",
                     :generic_traceback => "#aa0000"
                   }
                 )

  @doc """
  The *perldoc* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#perldoc).
  """
  def perldoc_style, do: @perldoc_style

  @rainbow_dash_style Style.make_style(
                        short_name: "rainbow_dash",
                        long_name: "RainbowDash Style",
                        background_color: "#ffffff",
                        highlight_color: "#ffffcc",
                        styles: %{
                          :text => "#4d4d4d",
                          :error => "bg:#cc0000 #ffffff",
                          :keyword => "bold #2c5dcd",
                          :keyword_pseudo => "nobold",
                          :keyword_type => "#5918bb",
                          :name_attribute => "italic #2c5dcd",
                          :name_builtin => "bold #5918bb",
                          :name_class => "underline",
                          :name_constant => "#318495",
                          :name_decorator => "bold #ff8000",
                          :name_entity => "bold #5918bb",
                          :name_exception => "bold #5918bb",
                          :name_function => "bold #ff8000",
                          :name_tag => "bold #2c5dcd",
                          :string => "#00cc66",
                          :string_doc => "italic",
                          :string_escape => "bold #c5060b",
                          :string_other => "#318495",
                          :string_symbol => "bold #c5060b",
                          :number => "bold #5918bb",
                          :operator => "#2c5dcd",
                          :operator_word => "bold",
                          :comment => "italic #0080ff",
                          :comment_preproc => "noitalic",
                          :comment_special => "bold",
                          :generic_deleted => "border:#c5060b bg:#ffcccc",
                          :generic_emph => "italic",
                          :generic_error => "#ff0000",
                          :generic_heading => "bold #2c5dcd",
                          :generic_inserted => "border:#00cc00 bg:#ccffcc",
                          :generic_output => "#aaaaaa",
                          :generic_prompt => "bold #2c5dcd",
                          :generic_strong => "bold",
                          :generic_subheading => "bold #2c5dcd",
                          :generic_traceback => "#c5060b"
                        }
                      )

  @doc """
  The *rainbow_dash* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#rainbow_dash).
  """
  def rainbow_dash_style, do: @rainbow_dash_style

  @rrt_style Style.make_style(
               short_name: "rrt",
               long_name: "Rrt Style",
               background_color: "#000000",
               highlight_color: "#0000ff",
               styles: %{
                 :keyword => "#ff0000",
                 :keyword_type => "#ee82ee",
                 :name_constant => "#7fffd4",
                 :name_function => "#ffff00",
                 :name_variable => "#eedd82",
                 :string => "#87ceeb",
                 :comment => "#00ff00",
                 :comment_preproc => "#e5e5e5"
               }
             )

  @doc """
  The *rrt* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#rrt).
  """
  def rrt_style, do: @rrt_style

  @tango_style Style.make_style(
                 short_name: "tango",
                 long_name: "Tango Style",
                 background_color: "#f8f8f8",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "#a40000 border:#ef2929",
                   :other => "#000000",
                   :keyword => "bold #204a87",
                   :keyword_constant => "bold #204a87",
                   :keyword_declaration => "bold #204a87",
                   :keyword_namespace => "bold #204a87",
                   :keyword_pseudo => "bold #204a87",
                   :keyword_reserved => "bold #204a87",
                   :keyword_type => "bold #204a87",
                   :name => "#000000",
                   :name_attribute => "#c4a000",
                   :name_builtin => "#204a87",
                   :name_builtin_pseudo => "#3465a4",
                   :name_class => "#000000",
                   :name_constant => "#000000",
                   :name_decorator => "bold #5c35cc",
                   :name_entity => "#ce5c00",
                   :name_exception => "bold #cc0000",
                   :name_function => "#000000",
                   :name_property => "#000000",
                   :name_label => "#f57900",
                   :name_namespace => "#000000",
                   :name_other => "#000000",
                   :name_tag => "bold #204a87",
                   :name_variable => "#000000",
                   :name_variable_class => "#000000",
                   :name_variable_global => "#000000",
                   :name_variable_instance => "#000000",
                   :literal => "#000000",
                   :string => "#4e9a06",
                   :string_backtick => "#4e9a06",
                   :string_char => "#4e9a06",
                   :string_doc => "italic #8f5902",
                   :string_double => "#4e9a06",
                   :string_escape => "#4e9a06",
                   :string_heredoc => "#4e9a06",
                   :string_interpol => "#4e9a06",
                   :string_other => "#4e9a06",
                   :string_regex => "#4e9a06",
                   :string_single => "#4e9a06",
                   :string_symbol => "#4e9a06",
                   :number => "bold #0000cf",
                   :number_float => "bold #0000cf",
                   :number_hex => "bold #0000cf",
                   :number_integer => "bold #0000cf",
                   :number_integer_long => "bold #0000cf",
                   :number_oct => "bold #0000cf",
                   :operator => "bold #ce5c00",
                   :operator_word => "bold #204a87",
                   :punctuation => "bold #000000",
                   :comment => "italic #8f5902",
                   :comment_multiline => "italic #8f5902",
                   :comment_preproc => "italic #8f5902",
                   :comment_single => "italic #8f5902",
                   :comment_special => "italic #8f5902",
                   :generic => "#000000",
                   :generic_deleted => "#a40000",
                   :generic_emph => "italic #000000",
                   :generic_error => "#ef2929",
                   :generic_heading => "bold #000080",
                   :generic_inserted => "#00A000",
                   :generic_output => "italic #000000",
                   :generic_prompt => "#8f5902",
                   :generic_strong => "bold #000000",
                   :generic_subheading => "bold #800080",
                   :generic_traceback => "bold #a40000"
                 }
               )

  @doc """
  The *tango* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#tango).
  """
  def tango_style, do: @tango_style

  @trac_style Style.make_style(
                short_name: "trac",
                long_name: "Trac Style",
                background_color: "#ffffff",
                highlight_color: "#ffffcc",
                styles: %{
                  :error => "bg:#e3d2d2 #a61717",
                  :keyword => "bold",
                  :keyword_type => "#445588",
                  :name_attribute => "#008080",
                  :name_builtin => "#999999",
                  :name_class => "bold #445588",
                  :name_constant => "#008080",
                  :name_entity => "#800080",
                  :name_exception => "bold #990000",
                  :name_function => "bold #990000",
                  :name_namespace => "#555555",
                  :name_tag => "#000080",
                  :name_variable => "#008080",
                  :string => "#bb8844",
                  :string_regex => "#808000",
                  :number => "#009999",
                  :operator => "bold",
                  :comment => "italic #999988",
                  :comment_preproc => "bold noitalic #999999",
                  :comment_special => "bold #999999",
                  :generic_deleted => "bg:#ffdddd #000000",
                  :generic_emph => "italic",
                  :generic_error => "#aa0000",
                  :generic_heading => "#999999",
                  :generic_inserted => "bg:#ddffdd #000000",
                  :generic_output => "#888888",
                  :generic_prompt => "#555555",
                  :generic_strong => "bold",
                  :generic_subheading => "#aaaaaa",
                  :generic_traceback => "#aa0000"
                }
              )

  @doc """
  The *trac* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#trac).
  """
  def trac_style, do: @trac_style

  @vim_style Style.make_style(
               short_name: "vim",
               long_name: "Vim Style",
               background_color: "#000000",
               highlight_color: "#222222",
               styles: %{
                 :error => "border:#FF0000",
                 :keyword => "#cdcd00",
                 :keyword_declaration => "#00cd00",
                 :keyword_namespace => "#cd00cd",
                 :keyword_type => "#00cd00",
                 :name_builtin => "#cd00cd",
                 :name_class => "#00cdcd",
                 :name_exception => "bold #666699",
                 :name_variable => "#00cdcd",
                 :string => "#cd0000",
                 :number => "#cd00cd",
                 :operator => "#3399cc",
                 :operator_word => "#cdcd00",
                 :comment => "#000080",
                 :comment_special => "bold #cd0000",
                 :generic_deleted => "#cd0000",
                 :generic_emph => "italic",
                 :generic_error => "#FF0000",
                 :generic_heading => "bold #000080",
                 :generic_inserted => "#00cd00",
                 :generic_output => "#888",
                 :generic_prompt => "bold #000080",
                 :generic_strong => "bold",
                 :generic_subheading => "bold #800080",
                 :generic_traceback => "#04D"
               }
             )

  @doc """
  The *vim* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#vim).
  """
  def vim_style, do: @vim_style

  @vs_style Style.make_style(
              short_name: "vs",
              long_name: "VisualStudio Style",
              background_color: "#ffffff",
              highlight_color: "#ffffcc",
              styles: %{
                :error => "border:#FF0000",
                :keyword => "#0000ff",
                :keyword_type => "#2b91af",
                :name_class => "#2b91af",
                :string => "#a31515",
                :operator_word => "#0000ff",
                :comment => "#008000",
                :comment_preproc => "#0000ff",
                :generic_emph => "italic",
                :generic_heading => "bold",
                :generic_prompt => "bold",
                :generic_strong => "bold",
                :generic_subheading => "bold"
              }
            )

  @doc """
  The *vs* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#vs).
  """
  def vs_style, do: @vs_style

  @xcode_style Style.make_style(
                 short_name: "xcode",
                 long_name: "Xcode Style",
                 background_color: "#ffffff",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "#000000",
                   :keyword => "#A90D91",
                   :name => "#000000",
                   :name_attribute => "#836C28",
                   :name_builtin => "#A90D91",
                   :name_builtin_pseudo => "#5B269A",
                   :name_class => "#3F6E75",
                   :name_decorator => "#000000",
                   :name_function => "#000000",
                   :name_label => "#000000",
                   :name_tag => "#000000",
                   :name_variable => "#000000",
                   :literal => "#1C01CE",
                   :string => "#C41A16",
                   :string_char => "#2300CE",
                   :number => "#1C01CE",
                   :operator => "#000000",
                   :comment => "#177500",
                   :comment_preproc => "#633820"
                 }
               )

  @doc """
  The *xcode* style. Example [here](https://elixir-makeup.github.io/makeup_demo/elixir.html#xcode).
  """
  def xcode_style, do: @xcode_style

  # %% End Pygments %%

  @samba_style Style.make_style(
                 short_name: "samba",
                 long_name: "Samba Style",
                 background_color: "#f8f8f8",
                 highlight_color: "#ffffcc",
                 styles: %{
                   :error => "#a40000 border:#ef2929",
                   :other => "#000000",
                   :keyword => "bold #204a87",
                   :keyword_constant => "bold #204a87",
                   :keyword_declaration => "bold #204a87",
                   :keyword_namespace => "bold #204a87",
                   :keyword_pseudo => "bold #204a87",
                   :keyword_reserved => "bold #204a87",
                   :keyword_type => "bold #204a87",
                   :name => "#000000",
                   :name_attribute => "#c4a000",
                   :name_builtin => "#204a87",
                   :name_builtin_pseudo => "#3465a4",
                   :name_class => "#5c35cc",
                   :name_constant => "#000000",
                   :name_decorator => "bold #5c35cc",
                   :name_entity => "#ce5c00",
                   :name_exception => "bold #cc0000",
                   :name_function => "#000000",
                   :name_property => "#000000",
                   :name_label => "#f57900",
                   :name_namespace => "#000000",
                   :name_other => "#000000",
                   :name_tag => "bold #204a87",
                   :name_variable => "#000000",
                   :name_variable_class => "#000000",
                   :name_variable_global => "#000000",
                   :name_variable_instance => "#000000",
                   :literal => "#000000",
                   :string => "#4e9a06",
                   :string_backtick => "#4e9a06",
                   :string_char => "#4e9a06",
                   :string_doc => "italic #8f5902",
                   :string_double => "#4e9a06",
                   :string_escape => "#4e9a06",
                   :string_heredoc => "#4e9a06",
                   :string_interpol => "#4e9a06",
                   :string_other => "#4e9a06",
                   :string_regex => "#4e9a06",
                   :string_single => "#4e9a06",
                   :string_symbol => "#4e9a06",
                   :number => "bold #0000cf",
                   :number_float => "bold #0000cf",
                   :number_hex => "bold #0000cf",
                   :number_integer => "bold #0000cf",
                   :number_integer_long => "bold #0000cf",
                   :number_oct => "bold #0000cf",
                   :operator => "bold #ce5c00",
                   :operator_word => "bold #204a87",
                   :punctuation => "#000000",
                   :comment => "#8e908c",
                   :comment_multiline => "#8e908c",
                   :comment_preproc => "#8e908c",
                   :comment_single => "#8e908c",
                   :comment_special => "#8e908c",
                   :generic => "#000000",
                   :generic_deleted => "#a40000",
                   :generic_emph => "italic #000000",
                   :generic_error => "#ef2929",
                   :generic_heading => "bold #000080",
                   :generic_inserted => "#00A000",
                   :generic_output => "italic #000000",
                   :generic_prompt => "#8f5902",
                   :generic_strong => "bold #000000",
                   :generic_subheading => "bold #800080",
                   :generic_traceback => "bold #a40000"
                 }
               )

  @doc """
  The *samba* style, based on the tango style, but with visual distinction between
  classes and variables, and lighter punctuation.
  """
  def samba_style, do: @samba_style
end
