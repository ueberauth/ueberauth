defmodule MIME.Mixfile do
  use Mix.Project

  @version "2.0.7"

  def project do
    [
      app: :mime,
      version: @version,
      elixir: "~> 1.10",
      description: "A MIME type module for Elixir",
      package: package(),
      deps: deps(),
      docs: [
        source_ref: "v#{@version}",
        main: "MIME",
        source_url: "https://github.com/elixir-plug/mime"
      ]
    ]
  end

  def package do
    [
      maintainers: ["alirz23", "José Valim"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/elixir-plug/mime"}
    ]
  end

  def application do
    [
      env: [],
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.19", only: :docs}
    ]
  end
end
