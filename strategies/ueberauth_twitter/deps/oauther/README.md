# OAuther

[![CI Status](https://github.com/lexmag/oauther/workflows/CI/badge.svg)](https://github.com/lexmag/oauther/actions/workflows/ci.yml)
[![Hex Version](https://img.shields.io/hexpm/v/oauther.svg)](https://hex.pm/packages/oauther)

OAuther is a library to authenticate using the [OAuth 1.0](http://tools.ietf.org/html/rfc5849) protocol.

All the standard signature methods are supported:

* HMAC-SHA1
* RSA-SHA1
* PLAINTEXT

This library also supports non-standard signature methods (that replace SHA-1 with stronger hashing algorithms):

* HMAC-SHA256

## Installation

Add the `:oauther` dependency to your `mix.exs` file:

```elixir
defp deps do
  [{:oauther, "~> 1.1"}]
end
```

Then, run `mix deps.get` in your shell to fetch the dependencies.

## Usage

The example below shows the use of [hackney HTTP client](https://github.com/benoitc/hackney)
for interacting with the Twitter API.
Protocol parameters are transmitted using the HTTP "Authorization" header.

```elixir
creds = OAuther.credentials(consumer_key: "dpf43f3p2l4k3l03", consumer_secret: "kd94hf93k423kf44", token: "nnch734d00sl2jdk", token_secret: "pfkkdhi9sl3r4s00")
#=> %OAuther.Credentials{
#=>   consumer_key: "dpf43f3p2l4k3l03",
#=>   consumer_secret: "kd94hf93k423kf44",
#=>   method: :hmac_sha1,
#=>   token: "nnch734d00sl2jdk",
#=>   token_secret: "pfkkdhi9sl3r4s00"
#=> }

params = OAuther.sign("post", "https://api.twitter.com/1.1/statuses/lookup.json", [{"id", 485086311205048320}], creds)
#=> [
#=>   {"oauth_signature", "ariK9GrGLzeEJDwQcmOTlf7jxeo="},
#=>   {"oauth_consumer_key", "dpf43f3p2l4k3l03"},
#=>   {"oauth_nonce", "L6a3Y1NeNwbU9Sqd6XnwNU+pjm6o0EyA"},
#=>   {"oauth_signature_method", "HMAC-SHA1"},
#=>   {"oauth_timestamp", 1517250224},
#=>   {"oauth_version", "1.0"},
#=>   {"oauth_token", "nnch734d00sl2jdk"},
#=>   {"id", 485086311205048320}
#=> ]

{header, req_params} = OAuther.header(params)
#=> {{"Authorization",
#=>   "OAuth oauth_signature=\"ariK9GrGLzeEJDwQcmOTlf7jxeo%3D\", oauth_consumer_key=\"dpf43f3p2l4k3l03\", oauth_nonce=\"L6a3Y1NeNwbU9Sqd6XnwNU%2Bpjm6o0EyA\", oauth_signature_method=\"HMAC-SHA1\", oauth_timestamp=\"1517250224\", oauth_version=\"1.0\", oauth_token=\"nnch734d00sl2jdk\""},
#=>  [{"id", 485086311205048320}]}

:hackney.post("https://api.twitter.com/1.1/statuses/lookup.json", [header], {:form, req_params})
#=> {:ok, 200, [...], #Reference<0.0.0.837>}
```

## License

OAuther is released under [the ISC license](LICENSE).
