#!/bin/bash
# Junta as licenças de tudo que vai dentro do app (as do Java ficam em Runtime/legal).
#   scripts/collect-licenses.sh <destino>
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?destino}
SRC=.build/deps/src
mkdir -p "$OUT"
cp LICENSE "$OUT/Toranja-LICENSE.txt"
cp THIRD-PARTY-NOTICES.md "$OUT/"
for lib in ffmpeg x264 lame opus libvpx libaom libwebp; do
    mkdir -p "$OUT/$lib"
    for f in COPYING COPYING.GPLv3 LICENSE LICENSE.md PATENTS; do
        [ -f "$SRC/$lib/$f" ] && cp "$SRC/$lib/$f" "$OUT/$lib/"
    done
done
for pkg in docx-preview jszip cupertino-files; do
    mkdir -p "$OUT/$pkg"
    cp -R office/js/node_modules/$pkg/LICENSE* office/js/node_modules/$pkg/THIRD-PARTY-NOTICES* "$OUT/$pkg/" 2>/dev/null || true
done
for jar in Resources/Java/lib/*.jar; do
    name=$(basename "$jar" .jar)
    for f in META-INF/LICENSE META-INF/LICENSE.txt META-INF/NOTICE META-INF/NOTICE.txt; do
        if unzip -p "$jar" "$f" >/dev/null 2>&1; then
            mkdir -p "$OUT/java/$name"
            unzip -p "$jar" "$f" > "$OUT/java/$name/$(basename "$f")"
        fi
    done
done
