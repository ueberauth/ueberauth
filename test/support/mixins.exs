defmodule Support.Mixins do
  defmacro __using__(_opts) do
    quote do
      alias Ueberauth.Auth.Info
      alias Ueberauth.Auth.Credentials
      alias Ueberauth.Auth.Extra


      def uid(_conn), do: "#{to_string(__MODULE__)}-uid"

      def info(_conn) do
        %Info{
          name: "Some name",
          first_name: "First name",
          last_name: "Last name",
          nickname: "Nickname",
          email: "email@foo.com",
          location: "Some location",
          description: "Some description",
          phone: "555-555-5555",
          urls: %{
            "Blog" => "http://foo.com",
            "Thing" => "http://thing.com",
          }
        }
      end

      def credentials(_conn) do
        %Credentials{
          token: "Some token",
          refresh_token: "Some refresh token",
          secret: "Some secret",
          expires: true,
          expires_at: 1111,
          other: %{
            password: "sekrit"
          }
        }
      end

      def extra(conn) do
        %Extra{
          raw_info: %{
            request_path: request_path(conn),
            callback_path: callback_path(conn),
            request_url: request_url(conn),
            callback_url: callback_url(conn)
          }
        }
      end

      defoverridable [uid: 1, info: 1, extra: 1, credentials: 1]
    end
  end
end
