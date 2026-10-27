#!/usr/bin/env bash
# Compila e instala YTTranscriber en esta Mac a partir del código fuente.
# Al compilarse acá, la app es local y macOS no la bloquea como a una app descargada.
# Uso: bash instalar.sh
set -euo pipefail

cd "$(dirname "$0")"
CLT="/Library/Developer/CommandLineTools"

echo "== Instalando YTTranscriber"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Esta Mac no tiene chip Apple (M1 o posterior). YTTranscriber necesita uno." >&2
    exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
    echo "YTTranscriber necesita macOS 14 (Sonoma) o superior. Esta Mac tiene $(sw_vers -productVersion)." >&2
    exit 1
fi

swift_major() {
    DEVELOPER_DIR="$CLT" "$CLT/usr/bin/swift" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1
}

if [[ ! -x "$CLT/usr/bin/swift" ]]; then
    echo
    echo "Faltan las herramientas gratuitas de Apple para compilar (Command Line Tools)."
    echo "Se va a abrir una ventana: tocá «Instalar» y después «Aceptar»."
    echo "La descarga tarda unos minutos. Esta ventana espera sola hasta que termine."
    xcode-select --install >/dev/null 2>&1 || true
    until [[ -x "$CLT/usr/bin/swift" ]]; do
        sleep 10
        printf "."
    done
    echo
fi

if [[ -z "$(swift_major)" ]] || (( $(swift_major) < 6 )); then
    echo "Las Command Line Tools están desactualizadas." >&2
    echo "Actualizalas en Ajustes del Sistema → General → Actualización de software y volvé a correr: bash instalar.sh" >&2
    exit 1
fi

# Cierra cualquier copia anterior, incluso una que haya quedado trabada al abrirse.
pkill -9 -x YTTranscriber 2>/dev/null || true

echo "== Compilando (la primera vez tarda unos minutos y necesita internet)"
bash ./build-app.sh --install

echo
echo "== Listo. Abriendo YTTranscriber…"
open /Applications/YTTranscriber.app
