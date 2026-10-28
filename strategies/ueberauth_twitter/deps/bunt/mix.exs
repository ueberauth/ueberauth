defmodule Bunt.Mixfile do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :bunt,
      version: @version,
      elixir: "~> 1.1",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Bunt",
      description: "256 color ANSI coloring in the terminal",
      package: [
        maintainers: ["René Föhring"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/rrrene/bunt"}
      ],
      docs: docs()
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      logo: "assets/logo.png",
      formatters: ["html"],
      extras: extras()
    ]
  end

  defp extras do
    ["README.md"]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    []
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:ex_doc, "~> 0.25", only: :dev, runtime: false}
    ]
  end
end
