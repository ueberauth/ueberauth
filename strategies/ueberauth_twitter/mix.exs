defmodule UeberauthTwitter.Mixfile do
  use Mix.Project

  @source_url "https://github.com/ueberauth/ueberauth"
  @source_path "strategies/ueberauth_twitter"
  @version "0.4.1"

  def project do
    [
      app: :ueberauth_twitter,
      version: @version,
      name: "Ueberauth Twitter Strategy",
      package: package(),
      elixir: "~> 1.14",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      source_url: @source_url,
      homepage_url: "#{@source_url}/tree/main/#{@source_path}",
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:httpoison, "~> 1.0"},
      {:oauther, "~> 1.1"},
      ueberauth_dep(),

      # dev/test dependencies
      {:ex_doc, "~> 0.18", only: :dev},
      {:credo, ">= 0.0.0", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      source_url_pattern:
        "#{@source_url}/blob/ueberauth_twitter-v#{@version}/#{@source_path}/%{path}#L%{line}",
      extras: [
        "CHANGELOG.md": [],
        "CONTRIBUTING.md": [title: "Contributing"],
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp package do
    [
      description: "An Uberauth strategy for Twitter authentication.",
      files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
      maintainers: ["Sean Callan"],
      licenses: ["MIT"],
      links: %{
        Changelog: "https://hexdocs.pm/ueberauth_twitter/changelog.html",
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
