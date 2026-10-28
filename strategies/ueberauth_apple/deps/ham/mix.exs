defmodule Ham.MixProject do
  use Mix.Project

  @source_url "https://github.com/edgurgel/ham"
  @version "0.3.2"

  def project do
    [
      app: :ham,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Docs
      name: "Ham",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    []
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "Runtime Type checking",
      licenses: ["Apache-2.0"],
      maintainers: [
        "Eduardo Gurgel"
      ],
      files: ["lib", "mix.exs", "LICENSE", "README.md"],
      links: %{
        "GitHub" => @source_url,
        "Mox" => "https://hex.pm/packages/ham"
      }
    ]
  end

  defp docs do
    [
      extras: [
        LICENSE: [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]

  defp elixirc_paths(_), do: ["lib"]
end
