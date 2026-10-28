defmodule SSLVerifyFun.Mixfile do
  use Mix.Project

  {:ok, [{:application, :ssl_verify_fun, props}]} = :file.consult("src/ssl_verify_fun.app.src")
  @props Keyword.take(props, [:applications, :description, :env, :mod, :vsn])

  def application do
    @props
  end

  def project do
    [app: :ssl_verify_fun,
     language: :erlang,
     version: to_string(@props[:vsn]),
     description: to_string(@props[:description]),
     package: package()]
  end

  defp package() do
    [maintainers: ["Ilya Khaprov"],
     licenses: ["MIT"],
     links: %{"GitHub" => "https://github.com/deadtrickster/ssl_verify_fun.erl"},
     files: ["src", "README.md", "LICENSE", "Makefile", "rebar.config", "mix.exs"]]
  end
end
