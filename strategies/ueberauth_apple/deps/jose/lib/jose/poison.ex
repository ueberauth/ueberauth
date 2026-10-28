if Code.ensure_loaded?(Poison) do
  defmodule JOSE.Poison do
    alias JOSE.Poison.LexicalEncoder

    @spec lexical_encode!(LexicalEncoder.t(), LexicalEncoder.options()) :: iodata | no_return
    def lexical_encode!(value, options \\ %{}) do
      iodata = LexicalEncoder.encode(value, options)

      if !options[:iodata] do
        iodata |> IO.iodata_to_binary()
      else
        iodata
      end
    end
  end
end
