#!/usr/bin/env bash
# Arma build/YTTranscriber-fuente.zip: el código fuente con instalar.sh, para compilar la app en otra Mac.
# Uso: ./package-source.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="YTTranscriber-fuente"
STAGE_ROOT="$ROOT/build/source-stage"
STAGE="$STAGE_ROOT/$NAME"
ZIP_PATH="$ROOT/build/$NAME.zip"

rm -rf "$STAGE_ROOT" "$ZIP_PATH"
mkdir -p "$STAGE"
for item in Package.swift Package.resolved build-app.sh instalar.sh README.md Resources scripts Sources Tests; do
    ditto "$ROOT/$item" "$STAGE/$item"
done
cp "$ROOT/Resources/LEEME-fuente.txt" "$STAGE/LEEME.txt"
chmod 755 "$STAGE/build-app.sh" "$STAGE/instalar.sh"

ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP_PATH"
rm -rf "$STAGE_ROOT"
echo "Zip listo: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
