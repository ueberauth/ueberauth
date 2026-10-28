defmodule Mimic.Cover do
  @moduledoc """
  Ensures mocked modules still get coverage data despite being replaced by `Mimic.Module`.
  Also ensures that coverage data from before moving the module around is not lost
  """

  @spec enabled_for?(module) :: boolean
  def enabled_for?(module) do
    :cover.is_compiled(module) != false
  end

  @doc false
  # Hack to allow us to use private functions on the :cover module.
  # Recompiles the :cover module but with all private functions as public.
  # Completely based on meck's solution:
  # https://github.com/eproxus/meck/blob/2c7ba603416e95401500d7e116c5a829cb558665/src/meck_cover.erl#L67-L91
  # Is idempotent.
  def export_private_functions do
    if not private_functions_exported?() do
      {_, binary, _} = :code.get_object_code(:cover)
      {:ok, {_, [{_, {_, abstract_code}}]}} = :beam_lib.chunks(binary, [:abstract_code])
      {:ok, module, binary} = :compile.forms(abstract_code, [:export_all])
      {:module, :cover} = :code.load_binary(module, ~c"", binary)
    end

    :ok
  end

  @doc false
  # Resets the module and ensures we haven't lost its coverdata
  def clear_module_and_import_coverdata!(module, original_beam_path, original_coverdata_path) do
    path = module |> Mimic.Module.original() |> export_coverdata!()
    rewrite_coverdata!(path, module)

    Mimic.Module.clear!(module)
    # Put back cover-compiled status for original module (don't need the private
    # compile_beams function here because the file should exist for the original module)
    :cover.compile_beam(original_beam_path)

    # Original module's coverdata would be lost due to purging it otherwise
    :ok = :cover.import(String.to_charlist(path))
    # Load coverdata from module from before the test
    :ok = :cover.import(String.to_charlist(original_coverdata_path))

    File.rm(path)
    File.rm(original_coverdata_path)
  end

  @doc false
  def export_coverdata!(module) do
    path = Path.expand("#{module}-#{:os.getpid()}.coverdata", ".")
    :ok = :cover.export(String.to_charlist(path), module)
    path
  end

  defp private_functions_exported? do
    function_exported?(:cover, :get_term, 1)
  end

  defp rewrite_coverdata!(path, module) do
    terms = get_terms(path)
    terms = replace_module_name(terms, module)
    write_coverdata!(path, terms)
  end

  defp replace_module_name(terms, module) do
    Enum.map(terms, fn term -> do_replace_module_name(term, module) end)
  end

  defp do_replace_module_name({:file, old, file}, module) do
    {:file, module, String.replace(file, to_string(old), to_string(module))}
  end

  defp do_replace_module_name({bump = {:bump, _mod, _, _, _, _}, value}, module) do
    {put_elem(bump, 1, module), value}
  end

  defp do_replace_module_name({_mod, clauses}, module) do
    {module, replace_module_name(clauses, module)}
  end

  defp do_replace_module_name(clause = {_mod, _, _, _, _}, module) do
    put_elem(clause, 0, module)
  end

  defp get_terms(path) do
    {:ok, resource} = File.open(path, [:binary, :read, :raw])
    terms = get_terms(resource, [])
    File.close(resource)
    terms
  end

  defp get_terms(resource, terms) do
    case apply(:cover, :get_term, [resource]) do
      :eof -> terms
      term -> get_terms(resource, [term | terms])
    end
  end

  defp write_coverdata!(path, terms) do
    {:ok, resource} = File.open(path, [:write, :binary, :raw])
    Enum.each(terms, fn term -> apply(:cover, :write, [term, resource]) end)
    File.close(resource)
  end
end
