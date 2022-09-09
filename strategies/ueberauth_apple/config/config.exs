# Note: This is only used for testing.
import Config

config :ueberauth,
  providers: [
    apple: {Ueberauth.Strategy.Apple, []}
  ]

config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
  client_id: "com.example.my-app",
  client_secret: "client-secret-abc123"
