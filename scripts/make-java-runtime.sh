#!/bin/bash
# Cria um Java enxuto (só os módulos usados pelo conversor Office) para ir dentro do app.
#   scripts/make-java-runtime.sh <destino>
set -euo pipefail
OUT=${1:?destino}
JDK=$(/usr/libexec/java_home -v 11+)
MODULES=java.base,java.desktop,java.xml,java.xml.crypto,java.logging,java.sql,java.naming,java.management,java.scripting,jdk.unsupported,jdk.zipfs
rm -rf "$OUT"
"$JDK/bin/jlink" --add-modules "$MODULES" --strip-debug --no-header-files --no-man-pages --compress=2 --output "$OUT"
