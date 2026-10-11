#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build FFmpeg 8.1.1 for the PS5 as static archives, for RPCS3's media decoding.
# Same component list RPCS3's ffmpeg-core uses (adapted from mihawk-99's
# PS5_RetroArch tools/build-ffmpeg.sh, 6ceb712). Output: deps/ffmpeg-ps5.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=8.1.1
digest=b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3
sdk="$root/deps/sdk-rpcs3"
prefix="$root/deps/ffmpeg-ps5"
stamp="$version $(sha256sum "$0" | cut -c1-64)"
[[ -f $prefix/.stamp && $(<"$prefix/.stamp") == "$stamp" ]] && { echo "==> [ffmpeg] $version already built"; exit 0; }
export PS5_PAYLOAD_SDK="$sdk"
nasm=$(command -v nasm) || { echo "nasm is required" >&2; exit 2; }
archive="$root/deps/downloads/ffmpeg-$version.tar.xz"
mkdir -p "$root/deps/downloads"
[[ -f $archive ]] || curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive"
printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status || { echo "FFmpeg archive digest mismatch" >&2; exit 1; }
build="$root/build/ffmpeg-ps5"
rm -rf -- "$build"; mkdir -p "$build/src"
tar -xJf "$archive" -C "$build/src" --strip-components=1
components=(
    --enable-decoder=aac --enable-decoder=aac_latm --enable-decoder=atrac3
    --enable-decoder=atrac3p --enable-decoder=atrac9 --enable-decoder=mp3
    --enable-decoder=pcm_s16le --enable-decoder=pcm_s8 --enable-decoder=mov
    --enable-decoder=h264 --enable-decoder=mpeg4 --enable-decoder=mpeg2video
    --enable-decoder=mjpeg --enable-decoder=mjpegb
    --enable-encoder=pcm_s16le --enable-encoder=mp3 --enable-encoder=ac3 --enable-encoder=aac
    --enable-encoder=ffv1 --enable-encoder=mpeg4 --enable-encoder=mjpeg --enable-encoder=h264
    --enable-muxer=avi --enable-muxer=h264 --enable-muxer=mjpeg --enable-muxer=mp4
    --enable-demuxer=h264 --enable-demuxer=m4v --enable-demuxer=mp3 --enable-demuxer=mpegvideo
    --enable-demuxer=mpegps --enable-demuxer=mjpeg --enable-demuxer=mov --enable-demuxer=avi
    --enable-demuxer=aac --enable-demuxer=pmp --enable-demuxer=oma --enable-demuxer=pcm_s16le
    --enable-demuxer=pcm_s8 --enable-demuxer=wav
    --enable-parser=h264 --enable-parser=mpeg4video --enable-parser=mpegaudio
    --enable-parser=mpegvideo --enable-parser=mjpeg --enable-parser=aac --enable-parser=aac_latm
    --enable-protocol=file --enable-bsf=mjpeg2jpeg
)
echo "==> [ffmpeg] configuring $version"
(cd "$build/src" && ./configure --prefix="$prefix" \
    --enable-cross-compile --target-os=freebsd --arch=x86_64 --cpu=znver2 \
    --cc="$sdk/bin/prospero-clang" --cxx="$sdk/bin/prospero-clang++" --ar="$sdk/bin/prospero-ar" \
    --ranlib="$sdk/bin/prospero-ranlib" --nm="$sdk/bin/prospero-nm" \
    --x86asmexe="$nasm" --pkg-config=false \
    --enable-static --disable-shared --enable-pic --disable-programs --disable-doc \
    --disable-debug --disable-autodetect --disable-avdevice --disable-avfilter \
    --disable-everything --disable-network "${components[@]}" \
    --extra-ldflags="-L$root/deps/ps5-extra-libs" > "$build/configure.log" 2>&1) ||
    { tail -30 "$build/configure.log" >&2; tail -40 "$build/src/ffbuild/config.log" >&2; exit 1; }
echo "==> [ffmpeg] building"
make -C "$build/src" -j"${JOBS:-26}" > "$build/make.log" 2>&1 || { grep -E "error" "$build/make.log" | head -30 >&2; exit 1; }
rm -rf -- "$prefix"
make -C "$build/src" install > "$build/install.log" 2>&1
printf '%s\n' "$stamp" > "$prefix/.stamp"
printf '==> [ffmpeg] %s: %s of archives in %s\n' "$version" "$(du -sh "$prefix/lib" | cut -f1)" "$prefix"
