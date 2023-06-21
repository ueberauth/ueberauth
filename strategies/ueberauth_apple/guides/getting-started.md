Setting up your application to use _Sign In with Apple_ requires a few steps:

1. Create and configure a Services ID in the [Apple Developer Console](https://developer.apple.com/account) and download a private key.
2. Install `:ueberauth_apple` (and `:ueberauth`, if not already installed).
3. Configure Ueberauth to include this library as a provider.
4. Configure this library, including a method of client secret generation.

Let's get started!

---

## Set Up with Apple

> #### Note {:.info}
>
> If you already have a Services ID with _Sign In with Apple_ set up, skip down to [Installation](#installation).

You can also check out the [official documentation](https://developer.apple.com/sign-in-with-apple/get-started/) for setting up _Sign In with Apple_.
Abbreviated instructions are included below.

**Prerequisites**

* You must have an Apple Developer account with **Account Holder** or **Admin** permissions.
* You must have an eligible domain to associate with your service (not `localhost`, `.test`, etc.).
* You must have a Primary App ID with _Sign In with Apple_ enabled.
  (For this, go to **Certificates, Identifiers & Profiles** and select the **Identifiers** tab ([direct link](https://developer.apple.com/account/resources/identifiers/list)).
  Then create or select your App ID, and enable the _Sign In with Apple_ capability.)

### Services ID

Services IDs establish a relationship between your website and your Apple Developer Program team and apps.
You may choose to have multiple Services IDs for multiple instances of your application (e.g. staging and production).
Each Services ID has a reverse-domain identifier, like `com.example.my-app`, that is distinct from your app IDs.
You can enable one or more services on each Service ID; for our purposes, only "Sign In with Apple" is necessary.

To set up a Services ID, perform the following:

1. Log in to your [Apple Developer](https://developer.apple.com/account) account.
2. Go to **Certificates, Identifiers & Profiles**, select the **Identifiers** tab, and then select **Services IDs** from the dropdown in the top-right ([direct link](https://developer.apple.com/account/resources/identifiers/list/serviceId)).
3. Click **+** to create a new identifier.
4. Select **Services IDs** and continue.
5. Provide a description (example `MyApp Staging`) and identifier (example `com.example.my-app-staging`).
6. Continue, and click **Register**.
7. You should now see the new Services ID in the list of all identifiers.
  Click it again to configure it.
8. Enable **Sign In with Apple** and click **Configure**.
9. If you have a published application (such as an iOS version of your app) already, you likely want to use that app's identifier as the Primary App ID.
  Learn more about grouping App IDs [here](https://help.apple.com/developer-account/#/dev04f3e1cfc).
10. Input all Domains and Subdomains that will act as origins for _Sign In with Apple_ requests.
11. Input the exact Return URL(s) your app will use during the OAuth flow.
  Usually these look like `https://my-app.example.com/auth/apple/callback`.
12. Confirm your choices. Once back at the Services ID configuration page, **Continue** and **Save**.

You now have a Services ID that is eligible to make requests to _Sign In with Apple_.
Currently, it is also necessary to provide `:ueberauth_apple` with the details necessary to make an API request to Apple.
This includes a private key.

### Private Key

After creating a Services ID, we also need to create a private key for use with API requests.

1. In the Apple Developer console, return to **Certificates, Identifiers & Profiles** and select the **Keys** tab ([direct link](https://developer.apple.com/account/resources/authkeys/list)).
2. Click **+** to create a new key.
3. Provide a name for the key (example `Sign In with Apple Staging`) and select **Sign In with Apple**.
  Click **Configure** for this service.
4. Select the same Primary App ID that was used for your Services ID.
  Be aware that this private key will be eligible to make requests against any of the grouped IDs (so even a staging key should be considered a production-level secret).
5. **Save** the Primary ID choice, **Continue**, and **Register**.
6. **Download** the new Key file and record the Key ID.
  Both of these pieces of information are necessary to generate a client secret later.

> #### Important {:.warning}
>
> Private Key files are critical secrets for your application.
> Even if you intend to use a Key only for testing, it has access to _Sign In with Apple_ for all Services IDs connected to the same Primary App ID.
> Use configuration best practices to provide these keys at runtime in the production environment.

---

## Installation

Now that you have a Services ID and Private Key set up with Apple, you can begin integrating _Sign In with Apple_ in your application.

### Package

Add `ueberauth_apple` as a dependency in `mix.exs` and run `mix deps.get`:

```elixir
def deps do
  [
    # ...
    {:ueberauth, "~> 0.10"},
    {:ueberauth_apple, "~> 0.6.1"},
  ]
end
```

### Provider Configuration

Then add this library as a provider in your configuration for Ueberauth:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    apple: {Ueberauth.Strategy.Apple, []}
  ]
```

The following options are available here, in the provider definition:

* `callback_methods`: List of HTTP methods to accept during the callback phase.
  Should be `["POST"]` if requesting any scopes (`name` or `email`), or `["GET"]` otherwise.
  Defaults to `["GET"]`. See also [Ueberauth's documentation](https://hexdocs.pm/ueberauth/readme.html#http-methods).

* `callback_path`: See [Ueberauth's documentation](https://hexdocs.pm/ueberauth/readme.html#customizing-paths).

* `callback_url`: URL to use as the Redirect URI parameter in the request phase.
  Defaults to a value based on the Phoenix Endpoint's host and the Ueberauth configuration.

* `default_scope`: Space-separated string of personal information to retrieve from Apple during sign-in.
  Available options are `name` and `email`.
  If any scopes are included, the `callback_methods` option must include `"POST"`.
  Defaults to no scopes, or `""`.

* `request_path`: See [Ueberauth's documentation](https://hexdocs.pm/ueberauth/readme.html#customizing-paths).

### Plug Integration

As with other Ueberauth providers, it is necessary to implement handlers for the callback phase.
This usually includes adding `Ueberauth` as a plug in an authentication-related controller:

```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller
  plug Ueberauth
  # ...
end
```

Then, implement handlers for success and failure cases during the callback phase:

```elixir
defmodule MyAppWeb.AuthController do
  # ...

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    message = Enum.map_join(failure.errors, "; ", fn error -> error.message end)

    conn
    |> put_flash(:error, "An error occurred during authentication: #{message}")
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case MyApp.Accounts.create_or_update_user(auth) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Successfully logged in")
        |> log_in_and_redirect_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "An error occurred while saving login")
        |> redirect(to: "/")
    end
  end
end
```

Finally, ensure the relevant routes are available in the router:

```elixir
defmodule MyAppWeb.Router
  # ...

  scope "/auth", UeberauthExampleWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request

    # Include this for requests with no scopes, or if you use other providers that require it.
    get "/:provider/callback", AuthController, :callback

    # Include this for requests with any scopes (name and/or email).
    post "/:provider/callback", AuthController, :callback
  end
end
```

For further assistance, check out the [Ueberauth Example](https://github.com/ueberauth/ueberauth_example).

---

## OAuth Configuration

In addition to the configuration provided above, this library accepts configuration for its OAuth module.

```elixir
config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
  client_id: System.get_env("APPLE_CLIENT_ID"),
  client_secret: {MyApp.Apple, :client_secret}
```

The following options are available:

* `client_id`: (**Required**) OAuth client ID used during both the request and callback phases.
  This matches the reverse-domain Services ID registered with Apple.

* `client_secret`: (**Required**) OAuth client secret **OR** a function used to generate this secret.
  Apple restricts client secrets to a maximum lifetime of six months, so most applications will generate and cache this secret at runtime.
  Use a string as the value to define the secret directly, or `{Module, :function}` as the value to define the generator function (see below).

### Generating the Client Secret

See also the [official documentation](https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens#3262048) for more information.

A typical client secret generator might look like this:

```elixir
defmodule MyApp.Apple
  @expiration_sec 86400 * 180

  @spec client_secret(keyword) :: String.t()
  def client_secret(_config \\ []) do
    with {:error, :not_found} <- get_client_secret_from_cache() do
      secret =
        UeberauthApple.generate_client_secret(%{
          client_id: Application.fetch_env!(:my_app, :apple_client_id),
          expires_in: @expiration_sec,
          key_id: Application.fetch_env!(:my_app, :apple_private_key_id),
          team_id: Application.fetch_env!(:my_app, :apple_team_id),
          private_key: Application.fetch_env!(:my_app, :apple_private_key)
        })

      put_client_secret_in_cache(secret, @expiration_sec)
      secret
    end
  end
end
```

In this example, the `client_secret` configuration for the OAuth module would be `{MyApp.Apple, :client_secret}`.
The `config` argument supplied by this library includes basic information about the request, including the client ID if configured:

```elixir
[
  strategy: Ueberauth.Strategy.Apple.OAuth,
  site: "https://appleid.apple.com",
  authorize_url: "/auth/authorize",
  token_url: "/auth/token",
  redirect_uri: "https://my-app.example.com/auth/apple/callback",
  client_id: "com.example.my-app",
  client_secret: {MyApp.Apple, :client_secret}
]
```

Because client secret generation may take some time, it is recommended to use a caching mechanism (ETS, Redis, etc.) to hold the generated secret until its expiration.