defmodule UeberGithub.Mixfile do
  use Mix.Project

  def project do
    [app: :ueber_github,
     version: "0.1.0",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    [
     {:ueberauth, "~>0.1"},
     {:oauth2, "~> 0.5"}
    ]
  end
end
