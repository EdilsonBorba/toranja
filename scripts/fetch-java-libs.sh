#!/bin/bash
# Baixa do Maven Central as bibliotecas open source do conversor Office (Apache POI + PDFBox).
set -euo pipefail
DEST="${1:-Resources/Java/lib}"
mkdir -p "$DEST"
M=https://repo1.maven.org/maven2
while read -r path; do
    [ -z "$path" ] && continue
    file="$DEST/$(basename "$path")"
    [ -f "$file" ] || curl -fsSL "$M/$path" -o "$file"
done <<'LIST'
org/apache/poi/poi/5.5.1/poi-5.5.1.jar
org/apache/poi/poi-ooxml/5.5.1/poi-ooxml-5.5.1.jar
org/apache/poi/poi-ooxml-lite/5.5.1/poi-ooxml-lite-5.5.1.jar
org/apache/poi/poi-scratchpad/5.5.1/poi-scratchpad-5.5.1.jar
org/apache/xmlbeans/xmlbeans/5.3.0/xmlbeans-5.3.0.jar
commons-codec/commons-codec/1.20.0/commons-codec-1.20.0.jar
org/apache/commons/commons-collections4/4.5.0/commons-collections4-4.5.0.jar
org/apache/commons/commons-compress/1.28.0/commons-compress-1.28.0.jar
commons-io/commons-io/2.21.0/commons-io-2.21.0.jar
org/apache/commons/commons-lang3/3.18.0/commons-lang3-3.18.0.jar
org/apache/commons/commons-math3/3.6.1/commons-math3-3.6.1.jar
commons-logging/commons-logging/1.3.5/commons-logging-1.3.5.jar
com/github/virtuald/curvesapi/1.08/curvesapi-1.08.jar
com/zaxxer/SparseBitSet/1.3/SparseBitSet-1.3.jar
org/apache/logging/log4j/log4j-api/2.24.3/log4j-api-2.24.3.jar
org/apache/pdfbox/pdfbox/3.0.6/pdfbox-3.0.6.jar
org/apache/pdfbox/pdfbox-io/3.0.6/pdfbox-io-3.0.6.jar
org/apache/pdfbox/fontbox/3.0.6/fontbox-3.0.6.jar
de/rototor/pdfbox/graphics2d/3.0.5/graphics2d-3.0.5.jar
LIST
echo "✓ bibliotecas Java em $DEST"
