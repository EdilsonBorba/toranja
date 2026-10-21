#!/bin/bash
# Compila um ffmpeg/ffprobe estático só com o que o Toranja usa, a partir do código-fonte oficial.
# Não depende de nada do Homebrew em tempo de execução (só pkg-config e cmake para compilar).
#   scripts/build-ffmpeg.sh <destino>      (ex.: Resources/Bin)
#   scripts/build-ffmpeg.sh --sources      só baixa os códigos-fonte (para publicar junto, como pede a GPL)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)/.build/deps
SRC=$ROOT/src
TARBALLS=$ROOT/sources
PREFIX=$ROOT/arm64
MIN=14.0
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=$MIN
export CFLAGS="-arch arm64 -mmacosx-version-min=$MIN -O2"
export CXXFLAGS=$CFLAGS LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
mkdir -p "$SRC" "$PREFIX" "$TARBALLS"

fetch() { # url pasta — guarda o arquivo original e extrai
    local file=${1##*/}
    [[ $file == "$2"* ]] || file=$2-$file
    [ -f "$TARBALLS/$file" ] || { echo "↓ $file"; curl -fsSL -o "$TARBALLS/$file" "$1"; }
    [ -d "$SRC/$2" ] && return
    mkdir -p "$SRC/$2"
    tar -x -f "$TARBALLS/$file" -C "$SRC/$2" --strip-components 1
}
built() { [ -f "$PREFIX/lib/$1" ]; }

fetch https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz ffmpeg
fetch https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2 x264
fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame
fetch https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus
fetch https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.2.tar.gz libvpx
fetch https://storage.googleapis.com/aom-releases/libaom-3.13.1.tar.gz libaom
fetch https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz libwebp
[ "${1:-}" = "--sources" ] && { echo "✓ códigos-fonte em $TARBALLS"; exit 0; }
OUT=$(cd "$(dirname "${1:?destino}")" && pwd)/$(basename "$1")

built libx264.a || (cd "$SRC/x264" && ./configure --prefix="$PREFIX" --host=aarch64-apple-darwin --enable-static \
    --disable-cli --enable-pic && make -j"$JOBS" && make install-lib-static)

built libmp3lame.a || (cd "$SRC/lame" && sed -i '' '/lame_init_old/d' include/libmp3lame.sym && \
    ./configure --prefix="$PREFIX" --host=aarch64-apple-darwin --disable-shared --enable-static --disable-frontend \
    --disable-dependency-tracking && make -j"$JOBS" && make install)

built libopus.a || (cd "$SRC/opus" && ./configure --prefix="$PREFIX" --host=aarch64-apple-darwin --disable-shared \
    --enable-static --disable-doc --disable-extra-programs && make -j"$JOBS" && make install)

built libvpx.a || (cd "$SRC/libvpx" && ./configure --prefix="$PREFIX" --target=arm64-darwin23-gcc --enable-static \
    --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth \
    --extra-cflags="-mmacosx-version-min=$MIN" && make -j"$JOBS" && make install)

built libaom.a || (mkdir -p "$SRC/libaom/out" && cd "$SRC/libaom/out" && cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN \
    -DBUILD_SHARED_LIBS=0 -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 >/dev/null && \
    make -j"$JOBS" && make install)

built libwebp.a || (cd "$SRC/libwebp" && ./configure --prefix="$PREFIX" --host=aarch64-apple-darwin --disable-shared \
    --enable-static --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic && make -j"$JOBS" && make install)

cd "$SRC/ffmpeg"
./configure --prefix="$PREFIX" --arch=arm64 --cc=clang --enable-gpl --enable-version3 --enable-static --disable-shared \
    --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
    --enable-libx264 --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libaom --enable-libwebp \
    --disable-ffplay --disable-doc --disable-network --disable-debug \
    --pkg-config-flags=--static --extra-cflags="-I$PREFIX/include $CFLAGS" --extra-ldflags="-L$PREFIX/lib $LDFLAGS" \
    --extra-libs="-lc++"
make -j"$JOBS"
mkdir -p "$OUT"
cp ffmpeg ffprobe "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"
echo "✓ ffmpeg → $OUT"
