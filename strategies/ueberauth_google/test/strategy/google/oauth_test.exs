defmodule Ueberauth.Strategy.Google.OAuthTest do
  use ExUnit.Case, async: true

  alias Ueberauth.Strategy.Google.OAuth

  defmodule MyApp.Google do
    def client_secret(_opts), do: "custom_client_secret"
  end

  describe "client/1" do
    test "uses client secret in the config when it is not a tuple" do
      assert %OAuth2.Client{client_secret: "client_secret"} = OAuth.client()
    end

    test "generates client secret when it is using a tuple config" do
      options = [client_secret: {MyApp.Google, :client_secret}]
      assert %OAuth2.Client{client_secret: "custom_client_secret"} = OAuth.client(options)
    end
  end
end
