defmodule Ueberauth.Mixfile do
  use Mix.Project

  @version "0.1.0"

  def project do
    [app: :ueberauth,
     name: "Überauth",
     version: @version,
     elixir: "~> 1.1",
     package: package,
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: "https://github.com/scrogson/ueberauth",
     homepage_url: "https://github.com/scrogson/ueberauth",
     description: description,
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    [{:plug, "~>1.0"},

     # Docs dependencies
     {:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.10", only: :dev}]
  end

  defp docs do
    [main: "Ueberauth"]
  end

  defp description do
    "An Elixir Authentication System for Plug-based Web Applications"
  end

  defp package do
    [files: ["lib", "priv", "mix.exs", "README.md", "LICENSE"],
       maintainers: ["Sonny Scroggin", "Daniel Neighman"],
       licenses: ["MIT"],
       links: %{github: "https://github.com/scrogson/ueberauth"}]
  end
end
