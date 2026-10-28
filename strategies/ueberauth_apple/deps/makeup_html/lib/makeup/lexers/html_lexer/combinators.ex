defmodule Makeup.Lexers.HTMLLexer.Combinators do
  @moduledoc false
  import NimbleParsec
  import Makeup.Lexer.Combinators

  def keyword(string), do: string |> token(:keyword)

  # Insensitive string
  # https://elixirforum.com/t/nimbleparsec-case-insensitive-matches/14339/2
  def anycase_string(string) do
    string
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reverse()
    |> char_piper
    |> reduce({List, :to_string, []})
  end

  defp char_piper([c]) when c in ?A..?Z do
    c
    |> both_cases
    |> ascii_char
  end

  defp char_piper([c | rest]) when c in ?A..?Z do
    rest
    |> char_piper
    |> ascii_char(both_cases(c))
  end

  defp char_piper([c]) do
    ascii_char([c])
  end

  defp char_piper([c | rest]) do
    rest
    |> char_piper
    |> ascii_char([c])
  end

  defp both_cases(c) do
    [c, c + 32]
  end

  def get_attributes do
    [
      "abbr",
      "accept",
      "accept-charset",
      "accesskey",
      "action",
      "allow",
      "allowfullscreen",
      "allowpaymentrequest",
      "alt",
      "as",
      "async",
      "autocapitalize",
      "autocomplete",
      "autofocus",
      "autoplay",
      "charset",
      "checked",
      "cite",
      "class",
      "color",
      "cols",
      "colspan",
      "content",
      "contenteditable",
      "controls",
      "coords",
      "crossorigin",
      "data",
      "datetime",
      "decoding",
      "default",
      "defer",
      "dir",
      "dirname",
      "disabled",
      "download",
      "draggable",
      "enctype",
      "enterkeyhint",
      "for",
      "form",
      "formaction",
      "formenctype",
      "formmethod",
      "formnovalidate",
      "formtarget",
      "headers",
      "height",
      "hidden",
      "high",
      "href",
      "hreflang",
      "http-equiv",
      "id",
      "imagesizes",
      "imagesrcset",
      "inputmode",
      "integrity",
      "is",
      "ismap",
      "itemid",
      "itemprop",
      "itemref",
      "itemscope",
      "itemtype",
      "kind",
      "label",
      "lang",
      "list",
      "loading",
      "loop",
      "low",
      "manifest",
      "max",
      "maxlength",
      "media",
      "method",
      "min",
      "minlength",
      "multiple",
      "muted",
      "name",
      "nomodule",
      "nonce",
      "novalidate",
      "open",
      "optimum",
      "pattern",
      "ping",
      "placeholder",
      "playsinline",
      "poster",
      "preload",
      "readonly",
      "referrerpolicy",
      "rel",
      "required",
      "reversed",
      "rows",
      "rowspan",
      "sandbox",
      "scope",
      "selected",
      "shape",
      "size",
      "sizes",
      "slot",
      "span",
      "spellcheck",
      "src",
      "srcdoc",
      "srclang",
      "srcset",
      "start",
      "step",
      "style",
      "tabindex",
      "target",
      "title",
      "translate",
      "type",
      "usemap",
      "value",
      "width",
      "wrap"
    ]
  end

  def get_event_handler_attributes do
    [
      "onabort",
      "onafterprint",
      "onauxclick",
      "onbeforeprint",
      "onbeforeunload",
      "onblur",
      "oncancel",
      "oncanplay",
      "oncanplaythrough",
      "onchange",
      "onclick",
      "onclose",
      "oncontextmenu",
      "oncopy",
      "oncuechange",
      "oncut",
      "ondblclick",
      "ondrag",
      "ondragend",
      "ondragenter",
      "ondragexit",
      "ondragleave",
      "ondragover",
      "ondragstart",
      "ondrop",
      "ondurationchange",
      "onemptied",
      "onended",
      "onerror",
      "onfocus",
      "onformdata",
      "onhashchange",
      "oninput",
      "oninvalid",
      "onkeydown",
      "onkeypress",
      "onkeyup",
      "onlanguagechange",
      "onload",
      "onloadeddata",
      "onloadedmetadata",
      "onloadstart",
      "onmessage",
      "onmessageerror",
      "onmousedown",
      "onmouseenter",
      "onmouseleave",
      "onmousemove",
      "onmouseout",
      "onmouseover",
      "onmouseup",
      "onoffline",
      "ononline",
      "onpagehide",
      "onpageshow",
      "onpaste",
      "onpause",
      "onplay",
      "onplaying",
      "onpopstate",
      "onprogress",
      "onratechange",
      "onrejectionhandled",
      "onreset",
      "onresize",
      "onscroll",
      "onsecuritypolicyviolation",
      "onseeked",
      "onseeking",
      "onselect",
      "onslotchange",
      "onstalled",
      "onstorage",
      "onsubmit",
      "onsuspend",
      "ontimeupdate",
      "ontoggle",
      "onunhandledrejection",
      "onunload",
      "onvolumechange",
      "onwaiting",
      "onwheel"
    ]
  end
end
