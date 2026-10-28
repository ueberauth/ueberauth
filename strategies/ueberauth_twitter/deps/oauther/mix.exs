defmodule OAuther.Mixfile do
  use Mix.Project

  def project() do
    [
      app: :oauther,
      version: "1.3.0",
      elixir: "~> 1.4",
      consolidate_protocols: Mix.env() != :test,
      description: description(),
      package: package()
    ]
  end

  def application() do
    [extra_applications: [:crypto, :public_key]]
  end

  defp description() do
    "A library to authenticate using the OAuth 1.0 protocol."
  end

  defp package() do
    [
      maintainers: ["Aleksei Magusev"],
      licenses: ["ISC"],
      links: %{"GitHub" => "https://github.com/lexmag/oauther"}
    ]
  end
end
