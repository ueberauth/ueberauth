# Builds the optional AEAD-context NIF.
#
# Built only on request: rebar.config and the Makefile shim run this when
# QUIC_BUILD_NIF=1 and fail the compile if it fails. Without the variable
# the library runs on OTP crypto (see quic_aead_ctx.erl).
#
# The NIF links against the SAME libcrypto that OTP's own crypto NIF
# uses, resolved from crypto.so with the platform's shared-library
# lister, so loading it never pins an incompatible OpenSSL into the VM
# before crypto.so loads. When that lookup fails we fall back to
# find_package(OpenSSL), and then to a bare -lcrypto.

cmake_minimum_required(VERSION 3.16)
project(quic_crypto_nif C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_program(ERL_EXECUTABLE erl)
if(NOT ERL_EXECUTABLE)
  message(FATAL_ERROR "erl not found; skipping the NIF")
endif()

# Ask the running OTP where its headers and its crypto NIF live.
function(erl_eval OUTVAR EXPR)
  execute_process(
    COMMAND ${ERL_EXECUTABLE} -noshell -boot no_dot_erlang -eval "${EXPR}"
    OUTPUT_VARIABLE _out
    ERROR_QUIET
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(${OUTVAR} "${_out}" PARENT_SCOPE)
endfunction()

erl_eval(ERTS_INCLUDE_DIR
  "io:format(\"~ts/erts-~ts/include\", [code:root_dir(), erlang:system_info(version)]), halt().")
erl_eval(OTP_CRYPTO_SO
  "io:format(\"~ts\", [filename:join([code:lib_dir(crypto), \"priv\", \"lib\", \"crypto.so\"])]), halt().")

if(NOT EXISTS "${ERTS_INCLUDE_DIR}/erl_nif.h")
  message(FATAL_ERROR "erl_nif.h not found under ${ERTS_INCLUDE_DIR}; skipping the NIF")
endif()

# Resolve the libcrypto OTP's crypto.so is already linked against.
# ldd on Linux and FreeBSD, otool -L on macOS: both print the absolute
# path of each dependency, so one regex covers them.
set(OTP_LIBCRYPTO "")
if(EXISTS "${OTP_CRYPTO_SO}")
  if(APPLE)
    find_program(LIB_LISTER otool)
    set(LIB_LISTER_ARGS -L)
  else()
    find_program(LIB_LISTER ldd)
    set(LIB_LISTER_ARGS "")
  endif()
  if(LIB_LISTER)
    execute_process(
      COMMAND ${LIB_LISTER} ${LIB_LISTER_ARGS} "${OTP_CRYPTO_SO}"
      OUTPUT_VARIABLE _deps ERROR_QUIET)
    # Absolute path ending in libcrypto{.so,.dylib}{.version}
    string(REGEX MATCH "(/[^ \t\n]*libcrypto[^ \t\n]*\\.(so|dylib)[^ \t\n]*)" _m "${_deps}")
    if(_m)
      set(OTP_LIBCRYPTO "${CMAKE_MATCH_1}")
    endif()
  endif()
endif()

if(OTP_LIBCRYPTO AND EXISTS "${OTP_LIBCRYPTO}")
  get_filename_component(OTP_LIBCRYPTO_DIR "${OTP_LIBCRYPTO}" DIRECTORY)
  get_filename_component(OPENSSL_PREFIX "${OTP_LIBCRYPTO_DIR}" DIRECTORY)
  set(OPENSSL_LIBRARIES "${OTP_LIBCRYPTO}")
  find_path(OPENSSL_INCLUDE_DIR openssl/evp.h
    HINTS "${OPENSSL_PREFIX}/include" NO_DEFAULT_PATH)
  if(NOT OPENSSL_INCLUDE_DIR)
    find_path(OPENSSL_INCLUDE_DIR openssl/evp.h)
  endif()
  message(STATUS "quic_crypto_nif: using OTP's libcrypto ${OTP_LIBCRYPTO}")
else()
  find_package(OpenSSL)
  if(OPENSSL_FOUND)
    message(STATUS "quic_crypto_nif: using find_package(OpenSSL) ${OPENSSL_VERSION}")
  else()
    set(OPENSSL_LIBRARIES crypto)
    message(STATUS "quic_crypto_nif: falling back to -lcrypto")
  endif()
endif()

if(NOT OPENSSL_INCLUDE_DIR OR NOT EXISTS "${OPENSSL_INCLUDE_DIR}/openssl/evp.h")
  message(FATAL_ERROR "openssl/evp.h not found; skipping the NIF")
endif()

# MODULE, not SHARED: a NIF is dlopen'd, never linked against, and on
# macOS MODULE gives a bundle rather than a dylib. erlang:load_nif/2
# appends ".so" on every platform, macOS included, so pin the suffix.
add_library(quic_crypto_nif MODULE quic_crypto_nif.c)
set_target_properties(quic_crypto_nif PROPERTIES
  PREFIX ""
  SUFFIX ".so"
  POSITION_INDEPENDENT_CODE ON
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../priv")

target_include_directories(quic_crypto_nif PRIVATE
  "${ERTS_INCLUDE_DIR}" "${OPENSSL_INCLUDE_DIR}")
target_link_libraries(quic_crypto_nif PRIVATE ${OPENSSL_LIBRARIES})
target_compile_options(quic_crypto_nif PRIVATE -Wall -Wextra)

# The enif_* symbols are resolved by the emulator at load time, so the
# link must tolerate them being undefined. ELF does by default; Mach-O
# needs telling.
if(APPLE)
  target_link_options(quic_crypto_nif PRIVATE -undefined dynamic_lookup)
endif()

# Keep the resolved libcrypto findable at load time without leaning on
# the system search path.
if(OTP_LIBCRYPTO_DIR)
  set_target_properties(quic_crypto_nif PROPERTIES
    BUILD_RPATH "${OTP_LIBCRYPTO_DIR}"
    INSTALL_RPATH "${OTP_LIBCRYPTO_DIR}")
endif()
