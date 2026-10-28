defmodule EarmarkParser.Message do
  @moduledoc false

  alias EarmarkParser.Context
  alias EarmarkParser.Options

  @type message_type :: :error | :warning | :deprecated
  @type t :: {message_type, non_neg_integer(), String.t()}
  @type ts :: [t()]
  @type container :: Options.t() | Context.t()

  @spec add_messages(container, ts()) :: container
  def add_messages(container, messages) do
    Enum.reduce(messages, container, &add_message(&2, &1))
  end

  @spec add_message(container, t()) :: container
  def add_message(container, message)

  def add_message(options = %Options{}, message) do
    %{options | messages: MapSet.put(options.messages, message)}
  end

  def add_message(context = %Context{}, message) do
    %{context | options: add_message(context.options, message)}
  end

  @spec get_messages(container) :: ts()
  def get_messages(container)

  def get_messages(%Context{options: %{messages: messages}}) do
    messages
  end

  @doc """
  For final output
  """
  @spec sort_messages(container) :: [t()]
  def sort_messages(container) do
    container
    |> get_messages()
    |> Enum.sort(fn {_, l, _}, {_, r, _} -> r >= l end)
  end
end

# SPDX-License-Identifier: Apache-2.0
