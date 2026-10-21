#!/bin/bash
# Compila o Toranja e monta build/Toranja.app.
#   ./build.sh           → só compila
#   ./build.sh install   → compila, copia para /Applications e abre
#   ./build.sh dist      → compila e gera em dist/ o .zip para download, o SHA-256 e os códigos-fonte do ffmpeg
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Conversor Office: bibliotecas Java open source (baixadas uma vez), nosso jar e o pacote JavaScript.
scripts/fetch-java-libs.sh Resources/Java/lib >/dev/null
if [ ! -f Resources/Java/toranja-office.jar ] || [ office/java/ToranjaOffice.java -nt Resources/Java/toranja-office.jar ]; then
    JDK=$(/usr/libexec/java_home)
    rm -rf .build/java && mkdir -p .build/java
    "$JDK/bin/javac" --release 11 -nowarn -cp "Resources/Java/lib/*" -d .build/java office/java/ToranjaOffice.java
    "$JDK/bin/jar" --create --file Resources/Java/toranja-office.jar -C .build/java .
fi
if [ ! -f Resources/JS/office.js ] || [ office/js/index.js -nt Resources/JS/office.js ]; then
    (cd office/js && npm install --no-audit --no-fund >/dev/null && npm run build >/dev/null)
fi

# Autossuficiente: ffmpeg/ffprobe compilados por nós e um Java enxuto vão dentro do app.
[ -x Resources/Bin/ffmpeg ] || scripts/build-ffmpeg.sh Resources/Bin
[ -x Resources/Runtime/bin/java ] || scripts/make-java-runtime.sh Resources/Runtime

APP=build/Toranja.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Toranja "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Sounds Resources/Java Resources/JS Resources/Bin Resources/Runtime "$APP/Contents/Resources/"
scripts/collect-licenses.sh "$APP/Contents/Resources/Licenses"
codesign --force --sign - "$APP/Contents/Resources/Bin/"*
codesign --force --sign - "$APP"
echo "✓ $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x Toranja 2>/dev/null || true
    rm -rf /Applications/Toranja.app
    cp -R "$APP" /Applications/
    open /Applications/Toranja.app
    echo "✓ Instalado em /Applications/Toranja.app"
fi

if [ "${1:-}" = "dist" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    rm -rf dist && mkdir dist
    ditto -c -k --keepParent "$APP" "dist/Toranja-$VERSION-AppleSilicon.zip"
    # A GPL pede que o código-fonte do ffmpeg (e bibliotecas) usado no binário acompanhe a distribuição.
    scripts/build-ffmpeg.sh --sources >/dev/null
    tar -c -f "dist/Toranja-$VERSION-ffmpeg-sources.tar" -C .build/deps sources -C "$PWD" scripts/build-ffmpeg.sh
    (cd dist && shasum -a 256 *.zip *.tar > SHA256SUMS.txt)
    ls -lh dist
fi
