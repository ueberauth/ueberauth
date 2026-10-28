#!/usr/bin/env bash
#
# quic_call.sh - erl_call-style one-shot RPC over quic_dist.
#
# erl_call only speaks inet_tcp_dist; this wrapper boots a hidden probe
# node with -proto_dist quic, connects to the target, runs an rpc:call/5,
# prints the result, and exits.
#
# Usage:
#   quic_call.sh [options] <Node> <Module> <Function> [ArgsTerm]
#
# ArgsTerm defaults to "[]". Must be a literal Erlang list term.
#
# Options (env var fallback in parentheses):
#   -c, --cookie COOKIE    dist cookie (COOKIE) - required
#   -C, --config FILE      sys.config with {quic, [{dist, [...]}]} (QUIC_SYS_CONFIG)
#       --cert FILE        TLS cert (QUIC_CERT) - required, auto-parsed from --config
#       --key FILE         TLS key  (QUIC_KEY)  - required, auto-parsed from --config
#       --verify MODE      verify_none | verify_peer (default verify_none)
#   -p, --port PORT        probe local listen port (QUIC_DIST_PORT, default 0)
#   -n, --name NAME        probe node name (default quic_call_$$@<host>)
#   -s, --sname            use -sname instead of -name
#   -t, --timeout MS       rpc:call timeout (default 10000)
#   -h, --help             show this help
#
# Exit codes:
#   0 on success, 2 on usage error,
#   3 if the probe node fails to start the quic application,
#   4 if it cannot connect to the target,
#   5 if rpc:call returns {badrpc, _}.

set -euo pipefail

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

COOKIE="${COOKIE:-}"
CONFIG="${QUIC_SYS_CONFIG:-}"
CERT="${QUIC_CERT:-}"
KEY="${QUIC_KEY:-}"
VERIFY="verify_none"
PORT="${QUIC_DIST_PORT:-0}"
NAME=""
NAME_FLAG="-name"
TIMEOUT="10000"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cookie)  COOKIE="$2"; shift 2 ;;
        -C|--config)  CONFIG="$2"; shift 2 ;;
        --cert)       CERT="$2"; shift 2 ;;
        --key)        KEY="$2"; shift 2 ;;
        --verify)     VERIFY="$2"; shift 2 ;;
        -p|--port)    PORT="$2"; shift 2 ;;
        -n|--name)    NAME="$2"; shift 2 ;;
        -s|--sname)   NAME_FLAG="-sname"; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "quic_call: unknown option $1" >&2; exit 2 ;;
        *)            break ;;
    esac
done

if [[ $# -lt 3 ]]; then
    usage >&2
    exit 2
fi

NODE="$1"
MOD="$2"
FUN="$3"
ARGS="${4:-[]}"

if [[ -z "$COOKIE" ]]; then
    echo "quic_call: cookie is required (-c, --cookie or \$COOKIE)" >&2
    exit 2
fi

# Auto-parse cert_file/key_file from sys.config when not given on CLI.
# The probe boots with -proto_dist quic, and quic_dist:listen/1 runs before
# the kernel finishes loading sys.config-defined app envs, so the credentials
# must come through -quic_dist_cert / -quic_dist_key init args.
#
# Take the string that follows each key, not the first string on its
# line: a config written on one line has both paths there, and the key
# used to come back as the certificate's path.
config_path() {
    sed -n "s/.*{$1, *\"\([^\"]*\)\".*/\1/p" "$CONFIG" 2>/dev/null | head -n 1
}
if [[ -n "$CONFIG" && -z "$CERT" ]]; then
    CERT="$(config_path cert_file)"
fi
if [[ -n "$CONFIG" && -z "$KEY" ]]; then
    KEY="$(config_path key_file)"
fi

if [[ -z "$CERT" || -z "$KEY" ]]; then
    echo "quic_call: --cert and --key are required (or set them in --config)" >&2
    exit 2
fi
if [[ ! -r "$CERT" ]]; then
    echo "quic_call: cert file not readable: $CERT" >&2
    exit 2
fi
if [[ ! -r "$KEY" ]]; then
    echo "quic_call: key file not readable: $KEY" >&2
    exit 2
fi

# Resolve the script's own absolute path without relying on realpath
# (not on every BSD/macOS by default).
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *)  SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
QUIC_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EBIN="${QUIC_EBIN:-$QUIC_DIR/ebin}"

if [[ ! -d "$EBIN" ]]; then
    echo "quic_call: quic ebin not found at $EBIN" >&2
    echo "  run 'rebar3 compile' or set QUIC_EBIN" >&2
    exit 2
fi

if [[ "$NAME_FLAG" == "-sname" ]]; then
    : "${NAME:=quic_call_$$}"
else
    HOST="$(hostname -s)"
    : "${NAME:=quic_call_$$@${HOST}}"
fi

ERL_ARGS=(
    "$NAME_FLAG" "$NAME"
    -setcookie "$COOKIE"
    -hidden
    -kernel net_setuptime 10
    -proto_dist quic
    -epmd_module quic_epmd
    -start_epmd false
    -quic_dist_port "$PORT"
    -quic_dist_cert "$CERT"
    -quic_dist_key "$KEY"
    -quic_dist_verify "$VERIFY"
    -pa "$EBIN"
    -noinput
)

if [[ -n "$CONFIG" ]]; then
    ERL_ARGS+=( -config "$CONFIG" )
fi

EVAL=$(cat <<ERL
case application:ensure_all_started(quic) of
    {ok, _} -> ok;
    {error, StartErr} ->
        io:format(standard_error, "quic start failed: ~p~n", [StartErr]),
        erlang:halt(3)
end,
case net_kernel:connect_node('${NODE}') of
    true -> ok;
    ConnErr ->
        io:format(standard_error, "connect failed: ~p~n", [ConnErr]),
        erlang:halt(4)
end,
RpcResult = rpc:call('${NODE}', '${MOD}', '${FUN}', ${ARGS}, ${TIMEOUT}),
%% Local disconnect_node + halt races the CONNECTION_CLOSE; have the
%% target drop us instead so the hidden-node entry is reaped now.
Self = node(),
_ = (catch rpc:call('${NODE}', erlang, disconnect_node, [Self], 2000)),
case RpcResult of
    {badrpc, BadRpc} ->
        io:format(standard_error, "badrpc: ~p~n", [BadRpc]),
        erlang:halt(5);
    Result ->
        io:format("~p~n", [Result]),
        erlang:halt(0)
end.
ERL
)

exec erl "${ERL_ARGS[@]}" -eval "$EVAL"
