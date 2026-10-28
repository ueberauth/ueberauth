defmodule UeberauthApple.Mixfile do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/ueberauth/ueberauth"
  @source_path "strategies/ueberauth_apple"

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
      source_url: @source_url,
      homepage_url: "#{@source_url}/tree/main/#{@source_path}",
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
      {:credo, ">= 0.0.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev},
      {:httpoison, "~> 3.0"},
      {:jose, "~> 1.0"},
      {:makeup_html, ">= 0.0.0", only: :dev, runtime: false},
      {:mimic, "~> 2.3.0", only: :test},
      {:oauth2, "~> 2.0"},
      ueberauth_dep()
    ]
  end

  defp docs do
    [
      source_url_pattern:
        "#{@source_url}/blob/ueberauth_apple-v#{@version}/#{@source_path}/%{path}#L%{line}",
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
      links: %{GitHub: "#{@source_url}/tree/main/#{@source_path}"}
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
