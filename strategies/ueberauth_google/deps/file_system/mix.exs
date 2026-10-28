defmodule FileSystem.MixProject do
  use Mix.Project

  @source_url "https://github.com/falood/file_system"
  @version "1.1.1"

  def project do
    [
      app: :file_system,
      version: @version,
      elixir: "~> 1.11",
      deps: deps(),
      description: description(),
      package: package(),
      consolidate_protocols: Mix.env() != :test,
      compilers: [:file_system | Mix.compilers()],
      aliases: ["compile.file_system": &file_system/1],
      docs: [
        extras: ["README.md"],
        main: "readme",
        source_url: @source_url,
        source_ref: "v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    An Elixir file system change watcher wrapper based on FS, the native file
    system listener.
    """
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end

  defp file_system(_args) do
    case :os.type() do
      {:unix, :darwin} -> compile_mac()
      _ -> :ok
    end
  end

  defp compile_mac do
    require Logger
    source = "c_src/mac/*.c"
    target = "priv/mac_listener"

    if Mix.Utils.stale?(Path.wildcard(source), [target]) do
      Logger.info("Compiling file system watcher for Mac...")

      cflags = System.get_env("CFLAGS", "")
      ldflags = System.get_env("LDFLAGS", "")

      cmd =
        "xcrun -r clang #{cflags} #{ldflags} -framework CoreFoundation -framework CoreServices -Wno-deprecated-declarations #{source} -o #{target}"

      if Mix.shell().cmd(cmd) > 0 do
        Logger.error(
          "Could not compile file system watcher for Mac, try to run #{inspect(cmd)} manually inside the dependency."
        )
      else
        Logger.info("Done.")
      end

      :ok
    else
      :noop
    end
  end

  defp package do
    %{
      maintainers: ["Xiangrong Hao", "Max Veytsman"],
      files: [
        "lib",
        "README.md",
        "mix.exs",
        "c_src/mac/cli.c",
        "c_src/mac/cli.h",
        "c_src/mac/common.h",
        "c_src/mac/compat.c",
        "c_src/mac/compat.h",
        "c_src/mac/main.c",
        "priv/inotifywait.exe"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end
end
