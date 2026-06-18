#!/bin/bash
set -euxo pipefail

# Skip mongo's tools/bazel wrapper guard so stock bazel works as $BAZEL_REAL.
export BAZELISK_SKIP_WRAPPER=1

# Generates the //bazel_toolchain package (conda compilers as a cc toolchain).
gen-bazel-toolchain

DEFINES=(
  # Mongo derives MONGO_VERSION from `git describe`; empty in tarball builds.
  --define=MONGO_VERSION="${PKG_VERSION}"
)

WRAPPER_INDEPENDENCE=(
  # .bazelrc defaults --build_enterprise=True; mongo's wrapper injects =False
  # but the injection is unreliable through stock bazel.
  --build_enterprise=False
  # Global select() with no_match_error in MONGO_LINUX_CC_COPTS, also applied
  # on macOS via MONGO_GLOBAL_COPTS.
  --//bazel/config:running_through_bazelisk=true
)

# Vendored asio falls through to std::result_of (removed in libc++ C++20);
# ASIO_HAS_STD_INVOKE_RESULT switches to std::invoke_result. Asio's own
# auto-detect for this only fires for MSVC. Must be global to avoid ODR
# violation across translation units that include asio headers.
THIRD_PARTY_CXX_COMPAT=(
  --copt=-DASIO_HAS_STD_INVOKE_RESULT=1
)

# gcc 14 promoted these C diagnostics from warning to default-error, which
# --disable_warnings_as_errors does not catch. Hit by vendored C deps
# (libbson, kms-message, wiredtiger, zlib, zstd, pcre2, timelib).
THIRD_PARTY_C_COMPAT=(
  --conlyopt=-Wno-error=implicit-function-declaration
  --conlyopt=-Wno-error=implicit-int
  --conlyopt=-Wno-error=int-conversion
  --conlyopt=-Wno-error=incompatible-pointer-types
)

COMMON_BAZEL_ARGS=(
  --config=local
  --crosstool_top=//bazel_toolchain:toolchain
  --disable_warnings_as_errors=True
  --extra_toolchains=//bazel_toolchain:cc_cf_toolchain
  --extra_toolchains=//bazel_toolchain:cc_cf_host_toolchain
)

case "$(uname -s)" in
Linux)
  PLATFORM_TOOLCHAIN_FLAGS=(
    --cxxopt=-std=c++20
    # Mongo overrides sized operator delete; -fsized-deallocation enables the
    # C++14 sized variant so mongo's overrides are reached.
    --cxxopt=-fsized-deallocation
    --conlyopt=-std=c11
    # libbson's bson-config.h hard-asserts BSON_HAVE_STRNLEN=1; strnlen is
    # gated on _GNU_SOURCE in glibc <string.h> and not visible under
    # __STRICT_ANSI__ from -std=c11.
    --conlyopt=-D_GNU_SOURCE
    # Mongo's source is not strict-aliasing-safe.
    --copt=-fno-strict-aliasing
    # tcmalloc records frame pointers for allocation-site sampling.
    --copt=-fno-omit-frame-pointer
    # Mongo's code expects exact float arithmetic; no fused multiply-add.
    --copt=-ffp-contract=off
    # std::thread on glibc requires explicit pthread linkage.
    --copt=-pthread
    --linkopt=-pthread
    # Mongo's native toolchain links libm/libresolv/libatomic by default
    # (global_libs feature) but bazel-toolchain does not.
    --linkopt=-lm
    # Mongo uses res_* functions for DNS resolution.
    --linkopt=-lresolv
    # Mongo uses 128-bit atomics; gcc requires explicit libatomic linkage.
    --linkopt=-latomic
    # Export dynamic symbols for mongo's backtrace symbol resolution.
    --linkopt=-rdynamic
  )
  PLATFORM_BAZEL_ARGS=(
    # Mongo source-level select() flag controlling compiler-specific paths.
    --compiler_type=gcc
  )
  ;;

Darwin)
  PLATFORM_TOOLCHAIN_FLAGS=(
    --cxxopt=-std=c++20
    --cxxopt=-fsized-deallocation
    --conlyopt=-std=c11
    --copt=-fno-strict-aliasing
    --copt=-fno-omit-frame-pointer
    --copt=-ffp-contract=off
    # libc++ advertises __cpp_lib_hardware_interference_size but does not
    # implement the constants. Mongo's fallback in stdx/new.h uses
    # alignof(std::max_align_t)=8 on arm64-darwin, under-sizing
    # CacheCombinedExclusive and failing the static_assert at aligned.h:65
    # for the 16-byte NetworkCounter::Together.
    --cxxopt=-DMONGO_CONFIG_MAX_EXTENDED_ALIGNMENT=64
  )
  PLATFORM_BAZEL_ARGS=(
    # Override .bazelrc :macos default of -c dbg.
    -c opt
    # Bazel's XcodeLocalEnvProvider reads DEVELOPER_DIR from action env;
    # xcode-select sets the system default but does not export the var.
    --action_env=DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
    --action_env=MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
  )
  ;;

*)
  echo "Unsupported platform: $(uname -s)" >&2
  exit 1
  ;;
esac

BAZEL_ARGS=(
  "${COMMON_BAZEL_ARGS[@]}"
  "${PLATFORM_BAZEL_ARGS[@]}"
  "${WRAPPER_INDEPENDENCE[@]}"
  "${PLATFORM_TOOLCHAIN_FLAGS[@]}"
  "${THIRD_PARTY_C_COMPAT[@]}"
  "${THIRD_PARTY_CXX_COMPAT[@]}"
  "${DEFINES[@]}"
)

# install-core builds mongod + mongos (per upstream docs/building.md).
bazel build "${BAZEL_ARGS[@]}" install-core

mkdir -p "${PREFIX}/bin"
cp -v bazel-bin/install/bin/mongod "${PREFIX}/bin/mongod"
cp -v bazel-bin/install/bin/mongos "${PREFIX}/bin/mongos"
chmod +x "${PREFIX}/bin/mongod" "${PREFIX}/bin/mongos"

# Remove bazel's large symlinked output trees.
bazel clean --expunge || true

