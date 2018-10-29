defmodule Ueberauth.Strategy do
  @moduledoc """
  The Strategy is the work-horse of the system.

  Strategies are implemented outside this library to meet your needs, the
  strategy provides a consistent API and behaviour.

  Your strategy may be called from the plug, or directly by developers to either authenticate
  or provide a request url

  Your strategy may be used anywhere, sockets, channels, controller actions or via the `Ueberauth.Plug`

  There are two callbacks for each strategy.

  1. request_url - use this url in clients to provide redirects for interacting with the auth provider
  2. authenticate - using params gathered from the client or elsewhere, call to the auth provider
                    and fetch the information to complete the `Ueberauth.Auth` struct
  """
  alias Ueberauth.{Auth, Failure}

  @type provider_name :: atom
  @type request_params :: %{
    required(:callback_url) => String.t,
    optional(:conn) => Plug.Conn.t
  }

  @doc """
  When called from a plug the following request params are provided:

  `%{conn: conn, callback_url: callback_url_as_string}`

  When called otherwise, specify your required parameters in your documentation
  """
  @callback request_url(request_params, options :: Keyword.t) :: {:ok, String.t} | {:error, term}

  @doc """
  Can be called from a plug or directly

  When called from a plug the following params will be provided:

  For get requests:

  `%{query: query_params, body: body_params, conn: conn}`

  For non-get requests:
  `%{query: query_params, conn: conn}`

  When called directly, specify in your documentation what the required parameters are.
  """
  @callback authenticate(provider_name, params :: map, options :: Keyword.t) :: {:ok, Auth.t} | {:error, Failure.t}
end
