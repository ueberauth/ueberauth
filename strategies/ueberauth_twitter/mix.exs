defmodule UeberauthTwitter.Mixfile do
  use Mix.Project

  @version "0.2.4"
  @url "https://github.com/ueberauth/ueberauth_twitter"

  def project do
    [app: :ueberauth_twitter,
     version: @version,
     name: "Ueberauth Twitter Strategy",
     package: package,
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: @url,
     homepage_url: @url,
     description: description,
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger, :httpoison, :oauth, :ueberauth]]
  end

  defp deps do
    [
     {:httpoison, "~> 0.7"},
     {:oauth, github: "tim/erlang-oauth"},
     {:poison, "~> 1.3 or ~> 2.0"},
     {:ueberauth, "~> 0.2"},

     # dev/test dependencies
     {:earmark, ">= 0.0.0", only: :dev},
     {:ex_doc, "~> 0.1", only: :dev},
     {:credo, "~> 0.5", only: [:dev, :test]}
    ]
  end

  defp docs do
    [extras: docs_extras, main: "extra-readme"]
  end

  defp docs_extras do
    ["README.md"]
  end

  defp description do
    "An Uberauth strategy for Twitter authentication."
  end

  defp package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
     maintainers: ["Sean Callan"],
     licenses: ["MIT"],
     links: %{"GitHub": @url}]
  end
end
