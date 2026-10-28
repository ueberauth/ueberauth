defmodule Earmark.Internal do
  @moduledoc ~S"""
  All public functions that are internal to Earmark, so that **only** external API
  functions are public in `Earmark`
  """

  alias Earmark.{Error, Message, Options, SysInterface, Transform}
  alias Earmark.EarmarkParserProxy, as: Proxy
  import Message, only: [emit_messages: 2]

  @doc ~S"""
  A wrapper to extract the AST from a call to `Earmark.Parser.as_ast` if a tuple `{:ok, result, []}` is returned,
  raise errors otherwise

      iex(1)> as_ast!(["Hello %% annotated"], annotations: "%%")
      [{"p", [], ["Hello "], %{annotation: "%% annotated"}}]

      iex(2)> as_ast!("===")
      ** (Earmark.Error) [{:warning, 1, "Unexpected line ==="}]

  """
  def as_ast!(markdown, options \\ [])

  def as_ast!(markdown, options) do
    case Proxy.as_ast(markdown, options) do
      {:ok, result, _} -> result
      {:error, _, messages} -> raise Earmark.Error, inspect(messages)
    end
  end

  @doc false
  def as_html(lines, options)

  def as_html(lines, options) when is_list(options) do
    case Options.make_options(options) do
      {:ok, options1} -> as_html(lines, options1)
      {:error, messages} -> {:error, "", messages}
    end
  end

  def as_html(lines, options) do
    {status, ast, messages} =
      Transform.postprocessed_ast(lines, %{options | messages: MapSet.new([])})

    {status, Transform.transform(ast, options), messages}
  end

  @spec as_html!([String.t()] | String.t(), Options.options()) :: String.t()
  def as_html!(lines, options \\ [])

  def as_html!(lines, options) do
    {_status, html, messages} = as_html(lines, options)
    emit_messages(messages, options)
    html
  end

  @doc ~S"""
  A utility function that will be passed as a partial capture to `EEx.eval_file` by
  providing a value for the `options` parameter

  ```elixir
      EEx.eval(..., include: &include(&1, options))
  ```

  thusly allowing

  ```eex
    <%= include.(some file) %>
  ```

  where `some file`  can be a relative path starting with `"./"`

  Here is an example using [these fixtures](https://github.com/pragdave/earmark/tree/master/test/fixtures)

      iex(3)> include("./include/basic.md.eex", file: "test/fixtures/does_not_matter")
      "# Headline Level 1\n"

  And here is how it is used inside a template

      iex(4)> options = [file: "test/fixtures/does_not_matter"]
      ...(4)> EEx.eval_string(~s{<%= include.("./include/basic.md.eex") %>}, include: &include(&1, options))
      "# Headline Level 1\n"
  """
  def include(filename, options \\ []) do
    options_ =
      options
      |> Options.relative_filename(filename)

    case Path.extname(filename) do
      ".eex" -> EEx.eval_file(options_.file, include: &include(&1, options_))
      _ -> SysInterface.readlines(options_.file) |> Enum.to_list()
    end
  end

  @doc ~S"""
  This is a convenience method to read a file or pass it to `EEx.eval_file` if its name
  ends in  `.eex`

  The returned string is then passed to `as_html` this is used in the escript now and allows
  for a simple inclusion mechanism, as a matter of fact an `include` function is passed

  """
  def from_file!(filename, options \\ [])

  def from_file!(filename, options) do
    filename
    |> include(options)
    |> as_html!()
  end

  @default_timeout_in_ms 5000
  @doc false
  def pmap(collection, func, timeout \\ @default_timeout_in_ms) do
    collection
    |> Enum.map(fn item -> Task.async(fn -> func.(item) end) end)
    |> Task.yield_many(timeout)
    |> Enum.map(&_join_pmap_results_or_raise(&1, timeout))
  end

  defp _join_pmap_results_or_raise(yield_tuples, timeout)
  defp _join_pmap_results_or_raise({_task, {:ok, result}}, _timeout), do: result

  defp _join_pmap_results_or_raise({task, {:error, reason}}, _timeout),
    do: raise(Error, "#{inspect(task)} has died with reason #{inspect(reason)}")

  defp _join_pmap_results_or_raise({task, nil}, timeout),
    do:
      raise(
        Error,
        "#{inspect(task)} has not responded within the set timeout of #{timeout}ms, consider increasing it"
      )
end

#  SPDX-License-Identifier: Apache-2.0
