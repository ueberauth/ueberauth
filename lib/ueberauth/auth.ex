defmodule Ueberauth.Auth do

  alias Ueberauth.Auth
  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  defstruct uid: nil,
            provider: nil,
            info: %Info{},
            credentials: %Credentials{},
            extra: %Extra{}

  def valid?(%Auth{} = auth), do: !!(auth.uid && auth.provider && auth.info && Info.valid?(auth.info))
  def valid?(_), do: false

  def from_params(params) do
    %Auth{}
    |> Map.put(:uid, Map.get(params, "uid", Map.get(params, :uid)))
    |> Map.put(:provider, Map.get(params, "provider", Map.get(params, :provider)))
    |> Map.put(:info, Info.from_params(params["info"] || params[:info]))
    |> Map.put(:credentials, Credentials.from_params(params["credentials"] || params[:credentials]))
    |> Map.put(:extra, Extra.from_params(params["extra"] || params[:extra]))
  end
end
