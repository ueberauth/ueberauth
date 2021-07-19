defmodule UeberauthTwitter.Mixfile do
  use Mix.Project

  @source_url "https://github.com/ueberauth/ueberauth_twitter"
  @version "0.4.0"

  def project do
    [
      app: :ueberauth_twitter,
      version: @version,
      name: "Überauth Twitter",
      elixir: "~> 1.1",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [applications: [:logger, :httpoison, :oauther, :ueberauth]]
  end

  defp deps do
    [
      {:httpoison, "~> 1.0"},
      {:oauther, "~> 1.1"},
      {:ueberauth, "~> 0.7"},

      # dev/test dependencies
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 0.8", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      extras: [
        "CHANGELOG.md": [],
        "CONTRIBUTING.md": [title: "Contributing"],
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end

  defp package do
    [
      description: "An Uberauth strategy for Twitter authentication.",
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Sean Callan"],
      licenses: ["MIT"],
      links: %{
        Changelog: "https://hexdocs.pm/ueberauth_twitter/changelog.html",
        GitHub: @source_url
      }
    ]
  end
end
