defmodule Ueberauth.Mixfile do
  use Mix.Project

  @version "0.5.0"

  def project do
    [app: :ueberauth,
     name: "Überauth",
     version: @version,
     elixir: "~> 1.4",
     package: package(),
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: "https://github.com/ueberauth/ueberauth",
     homepage_url: "https://github.com/ueberauth/ueberauth",
     description: description(),
     deps: deps(),
     docs: docs()]
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    [{:plug, "~> 1.2"},

     # dev/test dependencies
     {:credo, "~> 0.5", only: [:dev, :test]},
     {:earmark, "~> 0.2", only: :dev},
     {:ex_doc, "~> 0.12", only: :dev}]
  end

  defp docs do
    [extras: ["README.md", "CONTRIBUTING.md"]]
  end

  defp description do
    "An Elixir Authentication System for Plug-based Web Applications"
  end

  defp package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
     maintainers: ["Sonny Scroggin", "Daniel Neighman", "Sean Callan"],
     licenses: ["MIT"],
     links: %{"GitHub" => "https://github.com/ueberauth/ueberauth"}]
  end
end
