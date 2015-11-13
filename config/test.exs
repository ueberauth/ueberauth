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
  ]
