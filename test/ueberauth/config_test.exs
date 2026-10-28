defmodule Ueberauth.ConfigTest do
  # Not async: temporarily changes the global :ueberauth config.
  use ExUnit.Case, async: false

  import Plug.Test

  setup do
    config = Application.fetch_env!(:ueberauth, Ueberauth)
    on_exit(fn -> Application.put_env(:ueberauth, Ueberauth, config) end)
    %{config: config}
  end

  test "call/2 raises a descriptive error when no providers are configured", %{config: config} do
    options = Ueberauth.init()
    Application.put_env(:ueberauth, Ueberauth, Keyword.delete(config, :providers))

    assert_raise ArgumentError, ~r/no Ueberauth providers are configured/, fn ->
      Ueberauth.call(conn(:get, "/auth/simple"), options)
    end
  end

  test "call/2 reads provider config set after init/1", %{config: config} do
    # Phoenix may run init/1 at compile time, before config/runtime.exs is loaded.
    options = Ueberauth.init()

    Application.put_env(:ueberauth, Ueberauth,
      providers: [late: {Ueberauth.Strategy.Test, [uid: "runtime-uid"]}]
    )

    conn = Ueberauth.call(conn(:get, "/auth/late/callback"), options)
    assert Ueberauth.auth(conn).uid == "runtime-uid"

    Application.put_env(:ueberauth, Ueberauth, config)
    assert Ueberauth.call(conn(:get, "/auth/late/callback"), options).assigns == %{}
  end

  test "init/1 does not read the application config" do
    assert Ueberauth.init(providers: [:simple], base_path: "/login", other: :ignored) ==
             %{providers: [:simple], base_path: "/login"}
  end

  test "call/2 still accepts a list of routes" do
    routes = Ueberauth.routes()
    conn = Ueberauth.call(conn(:get, "/auth/test/callback"), routes)
    assert Ueberauth.auth(conn).uid == "test-uid"
  end
end
