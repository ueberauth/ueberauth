defmodule Makeup.Lexer.Types do
  @type token :: {atom(), map(), iodata()}
  @type tokens :: [token()]
  @type context :: map()
  @type parsec_success :: {:ok, tokens, String.t(), context(), {integer(), integer()}, integer()}
  @type parsec_failure :: {:error, String.t(), String.t(), context(), {integer(), integer()}, integer()}
  @type parsec_result :: parsec_success | parsec_failure
  @type parsec :: (String.t -> parsec_result)
end
