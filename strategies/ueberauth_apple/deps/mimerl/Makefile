PROJECT=mimerl
PROJECT_DESCRIPTION = library to handle mimetypes
PROJECT_VERSION = 1.5.0

UNIQ := $(shell command -v guniq >/dev/null 2>&1 && echo guniq || echo uniq)

include erlang.mk

.PHONY: gen

# Mimetypes module generator.

GEN_URL = https://raw.githubusercontent.com/apache/httpd/trunk/docs/conf/mime.types 
GEN_FILE = mime.types
GEN_SRC = src/mimerl.erl.src
GEN_OUT = src/mimerl.erl

gen:
	@wget -qO $(GEN_FILE) $(GEN_URL)
	@cat $(GEN_SRC) \
		| head -n `grep -n "%% GENERATED" $(GEN_SRC) | cut -d : -f 1` \
		> $(GEN_OUT)
	@cat $(GEN_FILE) \
		| grep -v ^# \
		| awk '{for (i=2; i<=NF; i++) if ($$i != "") { \
			print "extensions(<<\"" $$i "\">>) -> <<\"" $$1 "\">>;"}}' \
		| sort \
		| $(UNIQ) -w 25 \
		>> $(GEN_OUT)
	@echo "extensions(_) -> <<\"application/octet-stream\">>." >> $(GEN_OUT)
	@echo "" >> $(GEN_OUT)
	@cat $(GEN_FILE) \
		| grep -v ^# \
		| awk '{\
			printf("mimetypes(<<\"%s\">>) -> [", $$1); \
			for (i=2; i<=NF; i++) \
				if ($$i != "") { \
					if (i >= 3){printf(",")} \
					printf("<<\"%s\">>",  $$i) \
				}\
			print "];" \
			}' \
		| sort \
		>> $(GEN_OUT)
	@echo "mimetypes(_) -> [<<>>]." >> $(GEN_OUT)
	@cat $(GEN_SRC) \
		| tail -n +`grep -n "%% GENERATED" $(GEN_SRC) | cut -d : -f 1` \
		>> $(GEN_OUT)

.PHONY: doc deps test
