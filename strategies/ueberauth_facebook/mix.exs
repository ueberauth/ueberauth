defmodule UeberauthFacebook.Mixfile do
  use Mix.Project

  @version "0.6.0"
  @url "https://github.com/ueberauth/ueberauth_facebook"

  def project do
    [app: :ueberauth_facebook,
     version: @version,
     name: "Ueberauth Facebook Strategy",
     package: package,
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: @url,
     homepage_url: @url,
     description: description,
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger, :oauth2, :ueberauth]]
  end

  defp deps do
    [{:ueberauth, "~> 0.4"},
     {:oauth2, "~> 0.8.0"},

     {:ex_doc, "~> 0.2", only: :dev},
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
