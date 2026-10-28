defmodule Plug.Crypto.MixProject do
  use Mix.Project

  @version "2.2.1"
  @description "Crypto-related functionality for the web"
  @source_url "https://github.com/elixir-plug/plug_crypto"

  def project do
    [
      app: :plug_crypto,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      name: "Plug.Crypto",
      description: @description,
      docs: [
        main: "Plug.Crypto",
        source_ref: "v#{@version}",
        source_url: @source_url,
        extras: ["CHANGELOG.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:crypto],
      mod: {Plug.Crypto.Application, []}
    ]
  end

  defp deps do
    [{:ex_doc, "~> 0.21", only: :dev}]
  end

  defp package do
    %{
      licenses: ["Apache-2.0"],
      maintainers: [
        "Aleksei Magusev",
        "Andrea Leopardi",
        "Eric Meadows-Jönsson",
        "Gary Rennie",
        "José Valim"
      ],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"]
    }
  end
end
