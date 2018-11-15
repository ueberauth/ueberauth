defmodule Ueberauth.Mixfile do
  use Mix.Project

  @version "0.5.0"

  def project do
    [
      app: :ueberauth,
      name: "Überauth",
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/ueberauth/ueberauth",
      homepage_url: "https://github.com/ueberauth/ueberauth",
      description: description(),
      deps: deps(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [json_serializer: Jason]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, ">= 1.4.0", optional: true},
      {:jason, ">= 1.0.0", optional: true},
      {:oauth2, "~> 0.9"},

      # Tools
      {:dialyxir, ">= 0.0.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false}
    ]
  end

  defp docs do
    [extras: ["README.md", "CONTRIBUTING.md"]]
  end

  defp description do
    "An Elixir Authentication System for multi-phase Web Applications"
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Sonny Scroggin", "Daniel Neighman", "Sean Callan"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ueberauth/ueberauth"}
    ]
  end
end
