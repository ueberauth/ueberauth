defmodule UeberGithub.Mixfile do
  use Mix.Project

  @version "0.1.0"

  def project do
    [app: :ueber_github,
     version: @version,
     name: "Ueber Github",
     package: package,
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     source_url: "https://github.com/hassox/ueber_github",
     homepage_url: "https://github.com/hassox/ueber_github",
     description: description,
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    [
     {:ueberauth, "~>0.1"},
     {:oauth2, "~> 0.5"},

     # docs dependencies
     {:earmark, "~>0.1", only: :dev},
     {:ex_doc, "~>0.1", only: :dev}
    ]
  end

  defp docs do
    [extras: docs_extras, main: "extra-readme"]
  end

  defp docs_extras do
    ["README.md"]
  end

  defp description do
    "An Ueberauth strategy for using Github to authenticate your users."
  end

  defp package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Daniel Neighman"],
      licenses: ["MIT"],
      links: %{"GitHub": "https://github.com/hassox/ueber_github"}]
  end
end
