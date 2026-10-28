defmodule EarmarkParser.Helpers.PureLinkHelpers do
  @moduledoc false

  import EarmarkParser.Helpers.AstHelpers, only: [render_link: 2]

  def convert_pure_link(src) do
    pure_link_rgx = ~r{
      \A
      (\s*)
      (
        (?:https?://|www\.)
        [^\s<>]*
        [^\s<>?!.,:*_~]
      )
    }ux

    case Regex.run(pure_link_rgx, src) do
      [_match, spaces, link_text] ->
        if String.ends_with?(link_text, ")") do
          remove_trailing_closing_parens(spaces, link_text)
        else
          make_result(spaces, link_text)
        end

      _ ->
        nil
    end
  end

  defp remove_trailing_closing_parens(leading_spaces, link_text) do
    [_, link_text, trailing_parens] = Regex.run(~r{ (.*?) (\)*) \z}x, link_text)
    trailing_paren_count = String.length(trailing_parens)

    # try to balance parens from the rhs
    unbalanced_count = balance_parens(String.reverse(link_text), trailing_paren_count)
    balanced_parens = String.slice(trailing_parens, 0, trailing_paren_count - unbalanced_count)

    make_result(leading_spaces, link_text <> balanced_parens)
  end

  defp make_result(leading_spaces, link_text) do
    link =
      if String.starts_with?(link_text, "www.") do
        render_link("http://" <> link_text, link_text)
      else
        render_link(link_text, link_text)
      end

    if leading_spaces == "" do
      {link, String.length(link_text)}
    else
      {[leading_spaces, link], String.length(leading_spaces) + String.length(link_text)}
    end
  end

  # balance parens and return unbalanced *trailing* paren count
  defp balance_parens(reverse_text, trailing_count, non_trailing_count \\ 0)

  defp balance_parens(<<>>, trailing_paren_count, _non_trailing_count) do
    trailing_paren_count
  end

  defp balance_parens(_reverse_text, 0, _non_trailing_count) do
    0
  end

  defp balance_parens(")" <> rest, trailing_paren_count, non_trailing_count) do
    balance_parens(rest, trailing_paren_count, non_trailing_count + 1)
  end

  defp balance_parens("(" <> rest, trailing_paren_count, non_trailing_count) do
    # non-trailing paren must be balanced before trailing paren
    if non_trailing_count > 0 do
      balance_parens(rest, trailing_paren_count, non_trailing_count - 1)
    else
      balance_parens(rest, trailing_paren_count - 1, non_trailing_count)
    end
  end

  defp balance_parens(<<_::utf8, rest::binary>>, trailing_paren_count, non_trailing_count) do
    balance_parens(rest, trailing_paren_count, non_trailing_count)
  end
end
