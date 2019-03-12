defmodule Ueberauth.Auth.Info do
  @moduledoc """
  Provides a place within the Ueberauth.Auth struct for information about the user.
  """

  alias Ueberauth.Auth.Info

  @typedoc """
  A collection of the basic user information returned by third-party services.
  This is composed of a number of keys:

  + `:description` - A short description of the authenticating user.
  + `:email` - The e-mail of the authenticating user. Should be provided if at all possible (but some sites such as Twitter do not provide this information)
  + `:first_name` - The user's first name when available
  + `:image` -  A URL representing a profile image of the authenticating user. Where possible, should be specified to a square, roughly 50x50 pixel image.
  + `:last_name` - The user's last name
  + `:location` - The general location of the user, usually a city and state.
  + `:name` - The best display name known to the strategy. Usually a concatenation of first and last name, but may also be an arbitrary designator or nickname for some strategies
  + `:nickname` - The username of an authenticating user (such as your @-name from Twitter or GitHub account name)
  + `:phone` - The telephone number of the authenticating user (no formatting is enforced).
  + `:urls` - A map containing key value pairs of an identifier for the website and its URL. For instance, an entry could be "Blog" => "http://intridea.com/blog"
  """

  @type t :: %__MODULE__{
          description: binary | nil,
          email: binary | nil,
          first_name: binary | nil,
          image: binary | nil,
          last_name: binary | nil,
          location: binary | nil,
          name: binary | nil,
          nickname: binary | nil,
          phone: binary | nil,
          urls: map
        }

  defstruct description: nil,
            email: nil,
            first_name: nil,
            image: nil,
            last_name: nil,
            location: nil,
            name: nil,
            nickname: nil,
            phone: nil,
            urls: %{}

  def valid?(%Info{name: name}) when is_binary(name), do: true
  def valid?(_), do: false
end
