#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build zlib for the PS5 from RPCS3's own zlib submodule (static, PIC).
# libpng's generated configuration cannot see the in-tree zlib headers, so RPCS3
# is configured with USE_SYSTEM_ZLIB=ON pointing here. Output: deps/zlib-ps5.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/src/rpcs3/3rdparty/zlib/zlib"
build="$root/build/zlib-ps5"
prefix="$root/deps/zlib-ps5"
rm -rf "$build"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$root/cmake/ps5-rpcs3.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DZLIB_BUILD_EXAMPLES=OFF \
    -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON > /dev/null
ninja -C "$build" > /dev/null
rm -rf "$prefix"
ninja -C "$build" install > /dev/null
ls "$prefix"/lib/*.a
