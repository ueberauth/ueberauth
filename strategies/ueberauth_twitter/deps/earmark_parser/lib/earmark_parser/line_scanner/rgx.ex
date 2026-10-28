defmodule EarmarkParser.LineScanner.Rgx do
  @moduledoc ~S"""
  Exposes the regular expressions needed in the scanner in a more readable
  and optilized way by forcing them to be compiled at compile time in this
  module and then inlining them by means of exposed functions.
  """

  @compile {:inline,
            block_quote_matches: 1,
            bullet_list_item_matches: 1,
            dash_ruler_matches: 1,
            fence_matches: 1,
            footnote_def_matches: 1,
            heading_matches: 1,
            html_close_tag_matches: 1,
            html_comment_matches: 1,
            html_comment_start_matches: 1,
            html_one_line_matches: 1,
            html_open_tag_matches: 1,
            html_self_closing_matches: 1,
            ial_matches: 1,
            id_def_matches: 1,
            indent_matches: 1,
            numbered_list_item_matches: 1,
            set_ext_underline_matches: 1,
            star_ruler_matches: 1,
            table_column_rgx: 0,
            table_first_column_rgx: 0,
            table_header_rgx: 0,
            table_line_matches: 1,
            underline_ruler_matches: 1,
            void_tag_matches: 1,
            void_tag_rgx: 0}

  def block_quote_matches(content) do
    Regex.run(~r/\A > \s? (.*)/x, content)
  end

  def bullet_list_item_matches(content) do
    Regex.run(~r/\A ([-*+]) \s (\s*) (.*)/x, content)
  end

  def dash_ruler_matches(content) do
    Regex.run(~r/\A (?:-\s?){3,} \z/x, content)
  end

  def fence_matches(content) do
    Regex.run(~r/\A (\s*) (`{3,} | ~{3,}) \s* ([^`\s]*) \s* \z/ux, content)
  end

  def footnote_def_matches(content) do
    Regex.run(~r/\A \[\^([^\s\]]+)\] : \s+ (.*)/x, content)
  end

  # @heading ~r/\A
  # (\#{1,6}) \s+
  #   (?|(.*?) \s* #* \s* \z
  #   |
  #   (.*))/ux
  def heading_matches(content) do
    Regex.run(~r/\A(\#{1,6})\s+(?|(.*?)\s*#*\s*\z|(.*))/u, content)
  end

  def html_close_tag_matches(content) do
    Regex.run(~r/\A < \/ ([-\w]+?) >/x, content)
  end

  def html_comment_start_matches(content) do
    Regex.run(~r/\A <!-- .*? \z/x, content)
  end

  def html_comment_matches(content) do
    Regex.run(~r/\A <! (?: -- .*? -- \s* )+ > \z/x, content)
  end

  def html_one_line_matches(content) do
    Regex.run(~r/\A < ([-\w]+?) (?:\s.*)? > .* <\/\1>/x, content)
  end

  def html_open_tag_matches(content) do
    Regex.run(~r/\A < ([-\w]+?) (?:\s.*)? >/x, content)
  end

  def html_self_closing_matches(content) do
    Regex.run(~r/\A < ([-\w]+?) (?:\s.*)? \/> .*/x, content)
  end

  def set_ext_underline_matches(content) do
    Regex.run(~r/\A (=|-)+ \s* \z/x, content)
  end

  def ial_matches(content) do
    Regex.run(~r/\A {: (\s*[^}]+) } \s* \z/x, content)
  end

  @id_title_part ~S"""
        (?|
             " (.*)  "         # in quotes
          |  ' (.*)  '         #
          | \( (.*) \)         # in parens
        )
  """

  def id_def_matches(content) do
    Regex.run(
      ~r'''
        ^\[([^^].*?)\]:            # [someid]:
        \s+
        (?|
            < (\S+) >          # url in <>s
          |   (\S+)            # or without
        )
        (?:
            \s+                   # optional title
            #{@id_title_part}
        )?
        \s*
      $
      '''x,
      content
    )
  end

  def indent_matches(content) do
    Regex.run(
      ~r'''
        \A ( (?: \s{4})+ ) (\s*)                       # 4 or more leading spaces
        (.*)                                  # the rest
      '''x,
      content
    )
  end

  def numbered_list_item_matches(content) do
    Regex.run(~r/\A (\d{1,9} [.)] ) \s (\s*) (.*)/x, content)
  end

  def star_ruler_matches(content) do
    Regex.run(~r/\A (?:\*\s?){3,} \z/x, content)
  end

  def table_column_rgx do
    ~r/\A (\s*) .* \| /x
  end

  def table_first_column_rgx do
    ~r/\A (\s*) .* \s \| \s /x
  end

  def table_header_rgx do
    ~r/\[\[ .*? \]\]/x
  end

  def table_line_matches(content) do
    Regex.run(~r/\A \| (?: [^|]+ \|)+ \s* \z/x, content)
  end

  def underline_ruler_matches(content) do
    Regex.run(~r/\A (?:_\s?){3,} \z/x, content)
  end

  @void_tags ~w{area base br col embed hr img input link meta param source track wbr}
  def void_tag_rgx do
    ~r'''
    ^<( #{Enum.join(@void_tags, "|")} )
      .*?
      >
    '''x
  end

  def void_tag_matches(content) do
    Regex.run(void_tag_rgx(), content)
  end
end

# SPDX-License-Identifier: Apache-2.0
