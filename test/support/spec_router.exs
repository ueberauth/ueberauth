defmodule Support.SpecRouter do
  use Plug.Router
  require Ueberauth

  plug :fetch_query_params

  plug Ueberauth, base_path: "/auth"

  plug :match
  plug :dispatch

  get "/auth/simple", do: named(conn, "simple_request_phase")
  get "/auth/simple/callback", do: named(conn, "simple_callback")
  get "/auth/with_request_path/callback", do: named(conn, "with_request_path_callback")
  get "/login_callback", do: named(conn, "login_callback")
  get "/auth/using_default_options/callback", do: named(conn, "using_default_options_callback")
  get "/auth/using_custom_options/callback", do: named(conn, "using_custom_options_callback")
  get "/auth/with_errors/callback", do: named(conn, "with_errors_callback")
  post "/auth/post_callback/callback", do: named(conn, "post_callback")

  match _, do: send_resp(conn, 404, "oops")

  def named(conn, name), do: send_resp(conn, 200, name)
end

