#!/bin/sh
# Builds the optional NIF for rebar3. Opt-in: nothing is built unless
# QUIC_BUILD_NIF=1, and a requested build that fails fails the compile.
# Windows does not run this; see the hooks in rebar.config.

set -e
cd "$(dirname "$0")"

case "${1:-build}" in
    build)
        [ "$QUIC_BUILD_NIF" = 1 ] || exit 0
        cmake -S . -B build && cmake --build build || {
            echo "quic_crypto_nif: QUIC_BUILD_NIF=1 but the build failed;" \
                "install cmake, a C compiler and OpenSSL headers, or unset QUIC_BUILD_NIF" >&2
            exit 1
        }
        ;;
    clean)
        rm -rf build ../priv/quic_crypto_nif.so
        ;;
esac
