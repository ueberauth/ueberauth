defmodule Ham.Cache do
  @moduledoc false

  def put(key, value) do
    :persistent_term.put(key, value)
  end

  def get(key) do
    :persistent_term.get(key, nil)
  end

  def fetch(key, fetcher) do
    case get(key) do
      nil ->
        value = fetcher.()
        put(key, value)
        value

      value ->
        value
    end
  end
end
