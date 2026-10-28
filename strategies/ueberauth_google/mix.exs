defmodule UeberauthGoogle.Mixfile do
  use Mix.Project

  @source_url "https://github.com/ueberauth/ueberauth"
  @source_path "strategies/ueberauth_google"
  @version "0.13.0"

  def project do
    [
      app: :ueberauth_google,
      version: @version,
      name: "Üeberauth Google",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs()
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
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:mock, "~> 0.3", only: :test}
    ]
  end

  defp docs do
    [
      source_url_pattern: "#{@source_url}/blob/ueberauth_google-v#{@version}/#{@source_path}/%{path}#L%{line}",
      extras: ["CHANGELOG.md", "CONTRIBUTING.md", "README.md"],
      main: "readme",
      source_url: @source_url,
      homepage_url: "#{@source_url}/tree/main/#{@source_path}",
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
        GitHub: "#{@source_url}/tree/main/#{@source_path}"
      }
    ]
  end

  # Develop and test against the core library in this repository. Set
  # HEX_PUBLISH to build the package against the published Hex release.
  defp ueberauth_dep do
    if System.get_env("HEX_PUBLISH"),
      do: {:ueberauth, "~> 0.10"},
      else: {:ueberauth, path: "../.."}
  end
end
