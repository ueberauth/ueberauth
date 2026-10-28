defmodule JOSE.Mixfile do
  use Mix.Project

  def project() do
    [
      app: :jose,
      version: "1.11.13",
      elixir: "~> 1.13",
      erlc_options: erlc_options(),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "JOSE",
      source_url: "https://github.com/potatosalad/erlang-jose",
      docs: fn ->
        {ref, 0} = System.cmd("git", ["rev-parse", "--verify", "--quiet", "HEAD"])

        [
          source_ref: ref,
          main: "readme",
          extras: ["README.md", "CHANGELOG.md", "examples/KEY-GENERATION.md", "ALGORITHMS.md"],
          groups_for_modules: ["Elixir": [~r/JOSE/], Erlang: [~r/jose/]]
        ]
      end,
      description: description(),
      package: package(),
      aliases: [docs: ["compile", &edoc_chunks/1, "docs"]],
      dialyzer: [list_unused_filters: true]
    ]
  end

  def application() do
    [mod: {:jose_app, []}, extra_applications: extra_applications(Mix.env())]
  end

  defp extra_applications(env)
  defp extra_applications(:dev), do: [:crypto, :asn1, :public_key, :edoc, :xmerl]
  defp extra_applications(_env), do: [:crypto, :asn1, :public_key]

  defp deps() do
    [
      # {:cutkey, github: "potatosalad/cutkey", only: [:test]},
      {:jason, "~> 1.4.5", only: [:test]},
      {:jsone, "~> 1.9", only: [:test]},
      {:jsx, "~> 3.1", only: [:test]},
      # {:keccakf1600, "~> 2.0.0", only: [:test]},
      {:libdecaf, "~> 3.0.0", only: [:test]},
      {:libsodium, "~> 3.0.1", only: [:test]},
      {:ojson, "~> 1.0", only: [:test]},
      # Optionally used by JOSE.Poison.
      {:poison, "~> 3.0 or ~> 4.0 or ~> 5.0 or ~> 6.0", only: [:test], optional: true},
      {:thoas, "~> 1.2", only: [:test]},
      {:ex_doc, "~> 0.40.4", only: :dev},
      {:dialyxir, "~> 1.4.8", only: [:test], runtime: false}
    ]
  end

  defp description() do
    "JSON Object Signing and Encryption (JOSE) for Erlang and Elixir."
  end

  def erlc_options() do
    extra_options = []

    [:debug_info | if(Mix.env() == :prod, do: [], else: [:warnings_as_errors]) ++ extra_options]
  end

  defp package() do
    [
      maintainers: ["Andrew Bennett"],
      files: [
        "CHANGELOG*",
        "include",
        "lib",
        "LICENSE*",
        "priv",
        "mix.exs",
        "README*",
        "rebar.config",
        "src"
      ],
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/potatosalad/erlang-jose", "Docs" => "https://hexdocs.pm/jose"}
    ]
  end

  defp edoc_chunks(_args) do
    base_path = Path.dirname(__ENV__.file)
    doc_chunk_path = Application.app_dir(:jose, "doc")

    :ok =
      :edoc.application(:jose, String.to_charlist(base_path),
        doclet: :edoc_doclet_chunks,
        layout: :edoc_layout_chunks,
        preprocess: true,
        dir: String.to_charlist(doc_chunk_path)
      )
  end
end
