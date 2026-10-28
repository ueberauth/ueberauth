defmodule Ham do
  @moduledoc """
  Ham is a library for rigorous typespec checking for module functions including
  typespecs from implemented behaviours
  """

  @doc """
  Apply a module function validating arguments and return value against typespecs

      iex> Ham.apply(URI, :decode, ["https%3A%2F%2Felixir-lang.org"])
      "https://elixir-lang.org"
      iex> Ham.apply(URI, :char_reserved?, ["a"])
      ** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
        Value "a" does not match type 0..255.
  """
  @spec apply(module, atom, [any], Keyword.t()) :: any
  def apply(module, function_name, args, opts \\ []) do
    return_value = Kernel.apply(module, function_name, args)

    validate!(module, function_name, args, return_value, opts)

    return_value
  end

  @doc """
  Handy macro to apply a module function validating arguments and return value against typespecs

      iex> Ham.apply(URI.decode("https%3A%2F%2Felixir-lang.org"))
      "https://elixir-lang.org"
      iex> Ham.apply(URI.char_reserved?("a"))
      ** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
        Value "a" does not match type 0..255.
  """
  defmacro apply(call, opts \\ []) do
    case Macro.decompose_call(call) do
      :error ->
        raise ArgumentError, "Invalid call"

      {module, function_name, args} ->
        quote bind_quoted: [module: module, function_name: function_name, args: args, opts: opts] do
          Ham.apply(module, function_name, args, opts)
        end
    end
  end

  @doc """
  Validate arguments and return value against typespecs.

      iex> Ham.validate(URI, :char_reserved?, [?a], true)
      :ok
  """
  @spec validate(module, atom, [any], any, Keyword.t()) :: :ok | {:error, Ham.TypeMatchError.t()}
  def validate(module, function_name, args, return_value, opts \\ []) do
    behaviours = Keyword.get(opts, :behaviours, [])

    Ham.TypeChecker.validate(module, function_name, args, return_value, behaviours)
  end

  @doc """
  Validate arguments and return value against typespecs

      iex> Ham.validate!(URI, :char_reserved?, ["a"], true)
      ** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
        Value "a" does not match type 0..255.
  """
  @spec validate!(module, atom, [any], any, Keyword.t()) :: :ok | no_return
  def validate!(module, function_name, args, return_value, opts \\ []) do
    case validate(module, function_name, args, return_value, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
