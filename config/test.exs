use Mix.Config

config :ueberauth, Ueberauth,
  providers: [
    simple: { Support.SimpleCallback, [] },
    redirector: { Support.Redirector, [] },
    with_request_path: { Support.Redirector, [request_path: "/login"] },
    with_callback_path: { Support.SimpleCallback, [callback_path: "/login_callback"] },
    using_default_options: { Support.DefaultOptions, [] },
    using_custom_options: { Support.DefaultOptions, [the_uid: "custom uid"] },
    with_errors: { Support.WithErrors, [] },
    post_callback: { Support.SimpleCallback, [ callback_methods: ["POST"] ] },
    post_callback_and_same_request_path: { Support.SimpleCallback, [
      callback_methods: ["POST"],
      request_path: "/auth/post_callback_and_same_request_path",
      callback_path: "/auth/post_callback_and_same_request_path"
    ] },
    test_mode: { Support.TestMode, [] },
  ],
  test_mode: [
    test_mode: %{
      uid: "Elixir.Support.TestModeCallback-uid",
      info: %{
        a: 1
      },
      credentials: %{
        b: 2
      },
      extra: %{
        raw_info: %{
          c: 3
        }
      },
      provider: :test_mode,
      strategy: Support.TestMode
    }
  ]
