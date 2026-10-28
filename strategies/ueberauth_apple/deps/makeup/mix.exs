defmodule Makeup.Mixfile do
  use Mix.Project

  @version "1.2.2"
  @url "https://github.com/elixir-makeup/makeup"

  def project do
    [
      app: :makeup,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: compiler_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Package
      package: package(),
      description: description()
    ]
  end

  defp description do
    """
    Syntax highlighter for source code in the style of Pygments.
    """
  end

  def compiler_paths(:dev), do: ["test/helpers"] ++ compiler_paths(:prod)
  def compiler_paths(:test), do: ["test/helpers"] ++ compiler_paths(:prod)
  def compiler_paths(_), do: ["lib"]

  defp aliases do
    [
      docs: &build_docs/1
    ]
  end

  defp package do
    [
      name: :makeup,
      licenses: ["BSD-2-Clause"],
      maintainers: ["Tiago Barroso <tmbb@campus.ul.pt>"],
      links: %{
        "Changelog" => "https://hexdocs.pm/makeup/changelog.html",
        "Contributing" => "https://hexdocs.pm/makeup/contributing.html",
        "GitHub" => @url
      }
    ]
  end

  def application do
    [
      extra_applications: [:eex],
      mod: {Makeup.Application, []}
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp build_docs(_) do
    Mix.Task.run("compile")
    ex_doc = Path.join(Mix.path_for(:escripts), "ex_doc")

    unless File.exists?(ex_doc) do
      raise "cannot build docs because escript for ex_doc is not installed, run \"mix escript.install hex ex_doc\""
    end

    paths = Path.join(Mix.Project.build_path(), "lib/*/ebin")
    args = ["Makeup", @version, Mix.Project.compile_path()]
    opts = ~w[--main Makeup --source-ref v#{@version} --source-url #{@url} --config .ex_doc.exs]
    System.cmd(ex_doc, args ++ ["--paths", paths] ++ opts)
    Mix.shell().info("Docs built successfully")
  end
end
