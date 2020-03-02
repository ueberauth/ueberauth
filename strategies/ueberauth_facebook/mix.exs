defmodule Ueberauth.Facebook.Mixfile do
  use Mix.Project

  @version "0.8.1"
  @url "https://github.com/ueberauth/ueberauth_facebook"

  def project do
    [app: :ueberauth_facebook,
     version: @version,
     name: "Ueberauth Facebook Strategy",
     package: package(),
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: @url,
     homepage_url: @url,
     description: description(),
     deps: deps(),
     docs: docs()]
  end

  def application do
    [applications: [:logger, :oauth2, :ueberauth]]
  end

  defp deps do
    [{:ueberauth, "~> 0.6.0"},
     {:oauth2, "~> 1.0 or ~> 2.0"},

     {:credo, "~> 0.8.10", only: [:dev, :test]},
     {:ex_doc, "~> 0.19", only: :dev},
     {:earmark, ">= 0.0.0", only: :dev}]
  end

  defp docs do
    [extras: ["README.md", "CONTRIBUTING.md"]]
  end

  defp description do
    "An Uberauth strategy for Facebook authentication."
  end

  defp package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Sean Callan"],
      licenses: ["MIT"],
      links: %{"GitHub": @url}]
  end
end
