# Shim so erlang.mk, which runs c_src/Makefile unconditionally when it
# exists, builds the NIF the same way rebar3 does, through build_nif.sh.
#
# POSIX make only (no GNU extensions): FreeBSD and NetBSD run this with
# bmake.

all:
	@sh build_nif.sh

clean:
	@sh build_nif.sh clean

.PHONY: all clean
