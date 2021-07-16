defmodule UeberauthGoogle.Mixfile do
  use Mix.Project

  @source_url "https://github.com/ueberauth/ueberauth_google"
  @version "0.10.1"

  def project do
    [
      app: :ueberauth_google,
      version: @version,
      name: "Üeberauth Google",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :oauth2, :ueberauth]
    ]
  end

  defp deps do
    [
      {:oauth2, "~> 1.0 or ~> 2.0"},
      {:ueberauth, "~> 0.7.0"},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:mock, "~> 0.3", only: :test}
    ]
  end

  defp docs do
    [
      extras: ["CHANGELOG.md", "CONTRIBUTING.md", "README.md"],
      main: "readme",
      source_url: @source_url,
      homepage_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp package do
    [
      description: "An Uberauth strategy for Google authentication.",
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      maintainers: ["Sean Callan"],
      licenses: ["MIT"],
      links: %{
        Changelog: "https://hexdocs.pm/ueberauth_google/changelog.html",
        GitHub: @source_url
      }
    ]
  end
end
