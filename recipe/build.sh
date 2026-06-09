#!/bin/bash
set -x

# Vendored asio only auto-detects std::invoke_result for MSVC; on clang/gcc it falls
# through to std::result_of, that is removed in C++20. this define asio's own
# switch so it uses std::invoke_result instead
export CPPDEFINES="BOOST_ALL_DYN_LINK ASIO_HAS_STD_INVOKE_RESULT=1"

# https://jira.mongodb.org/browse/SERVER-30893
if [[ $target_platform == linux-aarch64 ]]; then
   export CFLAGS="${CFLAGS:-} -march=armv8-a+crc"
fi

if [[ $target_platform != $build_platform ]]; then
    unset _CONDA_PYTHON_SYSCONFIGDATA_NAME
fi

# https://github.com/llvm/llvm-project/commit/f47b8851
if [[ $target_platform =~ osx-* ]]; then
   export CFLAGS="${CFLAGS:-} -Wno-undef-prefix"
   export CPPDEFINES="${CPPDEFINES:-} _LIBCPP_DISABLE_AVAILABILITY"
fi

_conly_compat=""
if [[ $target_platform == linux-* ]]; then
   # gcc-14 promoted these C diagnostics to default-errors
   # --disable-warnings-as-errors does not catch default-error
   # promotions, and they are hit by vendored C
   _conly_compat="-Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types"
fi

export NINJA_STATUS="[%f+%r/%t] "

declare -a _scons_xtra_flags
_scons_xtra_flags+=(--dbg=off)
_scons_xtra_flags+=(--disable-warnings-as-errors)
_scons_xtra_flags+=(--enable-http-client=on)
_scons_xtra_flags+=(--opt=on)
_scons_xtra_flags+=(--release)
_scons_xtra_flags+=(--server-js=on)
_scons_xtra_flags+=(--ssl=on)
_scons_xtra_flags+=(--wiredtiger=on)
_scons_xtra_flags+=(--ninja=enabled)
_scons_xtra_flags+=(CC="$CC" CXX="$CXX" OBJCOPY="$OBJCOPY" CPPDEFINES="$CPPDEFINES")
_scons_xtra_flags+=(CCFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LINKFLAGS="$LDFLAGS")
_scons_xtra_flags+=(HOST_ARCH="$HOST")
_scons_xtra_flags+=(RPATH="$PREFIX/lib")
_scons_xtra_flags+=(VERBOSE=on)
_scons_xtra_flags+=(DESTDIR="$PREFIX")
_scons_xtra_flags+=(MONGO_VERSION="$PKG_VERSION")
_scons_xtra_flags+=(--use-system-{boost,icu,pcre2,snappy,yaml,zlib,zstd})

if [[ $target_platform == linux-* ]]; then
    _scons_xtra_flags+=(CFLAGS="$_conly_compat")
    # conda-forge gcc ships ld.bfd but not lld or gold and mongo 7.0's
    # default 'auto' linker requires lld (fatal if absent) and rejects bfd only for
    # dynamic builds; this build is static select bfd explicitly.
    _scons_xtra_flags+=(--linker=bfd)
fi

python buildscripts/scons.py "${_scons_xtra_flags[@]}" generate-ninja
ninja -f build.ninja install-core
