use Mix.Config

config :oauth2,
  serializers: %{
    "application/vnd.api+json" => Jason,
    "application/json" => Jason,
    "application/xml" => MyApp.XmlParser,
  }
