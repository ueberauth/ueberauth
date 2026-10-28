defmodule Ueberauth.Github.Mixfile do
  use Mix.Project

  @source_url "https://github.com/ueberauth/ueberauth"
  @source_path "strategies/ueberauth_github"
  @version "0.8.3"

  def project do
    [
      app: :ueberauth_github,
      version: @version,
      name: "Üeberauth GitHub",
      elixir: "~> 1.14",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:oauth2, "~> 1.0 or ~> 2.0"},
      ueberauth_dep(),
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      source_url_pattern:
        "#{@source_url}/blob/ueberauth_github-v#{@version}/#{@source_path}/%{path}#L%{line}",
      extras: [
        "CHANGELOG.md": [title: "Changelog"],
        "CONTRIBUTING.md": [title: "Contributing"],
        LICENSE: [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp package do
    [
      description: "An Ueberauth strategy for using Github to authenticate your users.",
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Daniel Neighman", "Sean Callan"],
      licenses: ["MIT"],
      links: %{
        Changelog: "https://hexdocs.pm/ueberauth_github/changelog.html",
        GitHub: "#{@source_url}/tree/main/#{@source_path}"
      }
    ]
  end

  # Develop and test against the core library in this repository. Set
  # HEX_PUBLISH to build the package against the published Hex release.
  defp ueberauth_dep do
    if System.get_env("HEX_PUBLISH"),
      do: {:ueberauth, "~> 0.7"},
      else: {:ueberauth, path: "../.."}
  end
end
