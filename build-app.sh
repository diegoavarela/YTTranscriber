#!/usr/bin/env bash
# Compila YTTranscriber en release, arma YTTranscriber.app con yt-dlp y deno incluidos,
# lo firma ad-hoc y opcionalmente lo instala o lo empaqueta en un zip para otra Mac.
# Uso: ./build-app.sh [--install] [--zip]
set -euo pipefail

APP_NAME="YTTranscriber"
BUNDLE_ID="com.diegovarela.YTTranscriber"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
VENDOR_DIR="$BUILD_DIR/vendor"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL=0
ZIP=0

# Herramientas incluidas en la app. Versiones y hashes fijos: si cambian, actualizarlos acá.
# yt-dlp se autoactualiza en la máquina del usuario; esta es solo la versión inicial.
YTDLP_VERSION="2026.10.21"
YTDLP_SHA256="7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40"
DENO_VERSION="2.9.8"
DENO_SHA256="9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e"

usage() { echo "Uso: $0 [--install] [--zip]"; }
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opción desconocida: $arg" >&2; usage >&2; exit 64 ;;
    esac
done

# Solo Command Line Tools, aunque xcode-select apunte a Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/swift" ]]; then
    echo "No se encontró swift en $DEVELOPER_DIR. Instalá las Command Line Tools: xcode-select --install" >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Este proyecto apunta a Apple Silicon (arm64)." >&2
    exit 1
fi

# Descarga $1 a $2 y verifica que su SHA-256 sea $3.
fetch_verified() {
    local url="$1" dest="$2" expected="$3" actual
    if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$expected" ]]; then
        return 0
    fi
    curl -fL --retry 3 --progress-bar -o "$dest.download" "$url"
    actual="$(shasum -a 256 "$dest.download" | cut -d' ' -f1)"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$dest.download"
        echo "Checksum inválido para $url" >&2
        echo "  esperado: $expected" >&2
        echo "  obtenido: $actual" >&2
        exit 1
    fi
    mv "$dest.download" "$dest"
}

cd "$ROOT"
echo "==> Compilando en release (toolchain: $DEVELOPER_DIR)"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Preparando yt-dlp $YTDLP_VERSION y deno $DENO_VERSION"
mkdir -p "$VENDOR_DIR"
fetch_verified "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos" \
    "$VENDOR_DIR/yt-dlp_macos-$YTDLP_VERSION" "$YTDLP_SHA256"
fetch_verified "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" \
    "$VENDOR_DIR/deno-$DENO_VERSION.zip" "$DENO_SHA256"
if [[ ! -x "$VENDOR_DIR/deno-$DENO_VERSION/deno" ]]; then
    rm -rf "$VENDOR_DIR/deno-$DENO_VERSION"
    mkdir -p "$VENDOR_DIR/deno-$DENO_VERSION"
    ditto -x -k "$VENDOR_DIR/deno-$DENO_VERSION.zip" "$VENDOR_DIR/deno-$DENO_VERSION"
fi

echo "==> Generando ícono"
ICON="$BUILD_DIR/AppIcon.icns"
if [[ ! -f "$ICON" || "$ROOT/scripts/make-icon.swift" -nt "$ICON" ]]; then
    ICON_WORK="$BUILD_DIR/icon"
    rm -rf "$ICON_WORK"
    mkdir -p "$ICON_WORK/AppIcon.iconset"
    swiftc -O "$ROOT/scripts/make-icon.swift" -o "$ICON_WORK/make-icon"
    "$ICON_WORK/make-icon" "$ICON_WORK/icon-1024.png"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_WORK/icon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_WORK/icon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICON"
    rm -rf "$ICON_WORK"
fi

echo "==> Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$VENDOR_DIR/yt-dlp_macos-$YTDLP_VERSION" "$APP/Contents/Helpers/yt-dlp"
cp "$VENDOR_DIR/deno-$DENO_VERSION/deno" "$APP/Contents/Helpers/deno"
chmod 755 "$APP/Contents/Helpers/"*
# Bundles de recursos de SwiftPM, si alguna dependencia los genera.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Firmando (ad-hoc)"
codesign --force -s - "$APP/Contents/Helpers/yt-dlp" "$APP/Contents/Helpers/deno"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$ZIP" == 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    STAGE="$BUILD_DIR/zip-stage/$APP_NAME"
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "==> Empaquetando $ZIP_PATH"
    rm -rf "$BUILD_DIR/zip-stage" "$ZIP_PATH"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    cp "$ROOT/Resources/LEEME.txt" "$STAGE/LEEME.txt"
    ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP_PATH"
    rm -rf "$BUILD_DIR/zip-stage"
    echo "Zip listo: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
fi

if [[ "$INSTALL" == 1 ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Instalando en $DEST"
    if pgrep -x "$APP_NAME" >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Listo: $DEST"
else
    echo "Listo: $APP"
fi
