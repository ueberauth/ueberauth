defmodule UeberauthApple.Mixfile do
  use Mix.Project

  @version "0.6.2"
  @url "https://github.com/ueberauth/ueberauth_apple"

  def project do
    [
      app: :ueberauth_apple,
      version: @version,
      name: "Ueberauth Apple Strategy",
      package: package(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      source_url: @url,
      homepage_url: @url,
      description: description(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev},
      {:httpoison, "~> 3.0"},
      {:jose, "~> 1.0"},
      {:makeup_html, ">= 0.0.0", only: :dev, runtime: false},
      {:mock, "~> 0.3.0", only: :test},
      {:oauth2, "~> 2.0"},
      {:ueberauth, "~> 0.10"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting-started.md": [title: "Getting Started"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "CODE_OF_CONDUCT.md": [title: "Code of Conduct"],
        LICENSE: [title: "License"]
      ]
    ]
  end

  defp description do
    "An Ueberauth strategy for Apple authentication."
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["AJ Foster"],
      licenses: ["MIT"],
      links: %{GitHub: @url}
    ]
  end
end
