defmodule UeberauthApple.Mixfile do
  use Mix.Project

  @version "0.4.0"
  @url "https://github.com/loopsocial/ueberauth_apple"

  def project do
    [
      app: :ueberauth_apple,
      version: @version,
      name: "Ueberauth Apple Strategy",
      package: package(),
      elixir: "~> 1.6",
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
    [applications: [:logger, :oauth2, :ueberauth]]
  end

  defp deps do
    [
      {:oauth2, ">= 0.0.0"},
      {:ueberauth, "~> 0.5"},
      {:jose, "~> 1.0"},
      {:httpoison, "~> 1.0"},
      {:credo, "~> 0.8", only: [:dev, :test]},
      {:earmark, ">= 0.0.0", only: :dev},
      {:ex_doc, "~> 0.3", only: :dev}
    ]
  end

  defp docs do
    [extras: ["README.md", "CONTRIBUTING.md"]]
  end

  defp description do
    "An Uberauth strategy for Apple authentication."
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Jerry Luk"],
      licenses: ["MIT"],
      links: %{GitHub: @url}
    ]
  end
end
