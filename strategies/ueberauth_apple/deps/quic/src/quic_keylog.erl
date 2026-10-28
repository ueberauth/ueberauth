%%% TLS key logging in the NSS Key Log format.
%%%
%%% Wireshark, and through it the QUIC Interop Runner, decrypts a capture
%%% by reading the traffic secrets from a file named by the SSLKEYLOGFILE
%%% environment variable. Several interop test cases refuse to grade a
%%% run without one: they return "unsupported" before looking at whether
%%% the transfer actually worked.
%%%
%%% Writing this file hands anyone who reads it the ability to decrypt the
%%% connection, so it stays off unless SSLKEYLOGFILE is set, and nothing
%%% here logs the secrets anywhere else.
-module(quic_keylog).

-export([log/3, enabled/0]).

-define(CLIENT_HANDSHAKE, "CLIENT_HANDSHAKE_TRAFFIC_SECRET").
-define(SERVER_HANDSHAKE, "SERVER_HANDSHAKE_TRAFFIC_SECRET").
-define(CLIENT_APP, "CLIENT_TRAFFIC_SECRET_0").
-define(SERVER_APP, "SERVER_TRAFFIC_SECRET_0").

-type label() ::
    client_handshake | server_handshake | client_application | server_application.

-export_type([label/0]).

-spec enabled() -> boolean().
enabled() ->
    case os:getenv("SSLKEYLOGFILE") of
        false -> false;
        "" -> false;
        _ -> true
    end.

%% @doc Append one secret to the key log. ClientRandom is the 32-byte
%% random from the ClientHello, which is what ties the line to a
%% connection; a missing one means the line cannot be matched to anything,
%% so it is dropped rather than written misleadingly.
-spec log(label(), binary() | undefined, binary() | undefined) -> ok.
log(Label, ClientRandom, Secret) when
    is_binary(ClientRandom), is_binary(Secret), byte_size(Secret) > 0
->
    case os:getenv("SSLKEYLOGFILE") of
        false ->
            ok;
        "" ->
            ok;
        Path ->
            Line = [
                label_text(Label),
                $\s,
                hex(ClientRandom),
                $\s,
                hex(Secret),
                $\n
            ],
            _ = file:write_file(Path, Line, [append]),
            ok
    end;
log(_Label, _ClientRandom, _Secret) ->
    ok.

label_text(client_handshake) -> ?CLIENT_HANDSHAKE;
label_text(server_handshake) -> ?SERVER_HANDSHAKE;
label_text(client_application) -> ?CLIENT_APP;
label_text(server_application) -> ?SERVER_APP.

hex(Bin) ->
    string:lowercase(binary:encode_hex(Bin)).
