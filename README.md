# YTTranscriber

App nativa de macOS (Apple Silicon, macOS 14+) para obtener la transcripción de un video de YouTube y copiarla.

1. Valida la URL (watch, youtu.be, shorts, embed, live, music).
2. Busca subtítulos en el idioma original del video con yt-dlp: primero manuales, después automáticos. Los convierte a texto limpio, sin marcas de tiempo ni líneas repetidas.
3. Si no hay subtítulos, baja solo el audio y lo transcribe localmente con [WhisperKit](https://github.com/argmaxinc/WhisperKit) (modelo `large-v3-v20240930_turbo`), detectando el idioma.

Las transcripciones se guardan en caché por ID de video en `~/Library/Caches/YTTranscriber/transcripts/`.

## Requisitos

- Mac con Apple Silicon y macOS 14 o superior.
- Para compilar: Command Line Tools (no hace falta Xcode), con `xcode-select --install`, y conexión a internet la primera vez.

Para usarla no hace falta instalar nada más. La app trae adentro (`Contents/Helpers`) las versiones fijas de [yt-dlp](https://github.com/yt-dlp/yt-dlp) (binario standalone) y [deno](https://deno.com), que yt-dlp usa para resolver YouTube. El script las descarga y verifica su SHA-256. El audio se convierte con `afconvert`, que viene con macOS, así que no se usa ffmpeg.

La primera vez que se abre, la app copia esas herramientas a `~/Library/Application Support/YTTranscriber/bin/`. Ahí yt-dlp se autoactualiza (`yt-dlp -U`) como mucho una vez por día y, además, cada vez que YouTube rechaza una descarga (HTTP 403 o verificación de bot). Después de actualizarse reintenta una vez. Si la app se corre fuera de un `.app` (por ejemplo con `swift run`), usa el yt-dlp de Homebrew.

## Descargar e instalar

En la Terminal:

```sh
git clone https://github.com/diegoavarela/YTTranscriber.git
bash YTTranscriber/instalar.sh
```

También se puede bajar el zip desde GitHub (**Code → Download ZIP**), descomprimirlo y correr `bash instalar.sh` adentro de la carpeta. El script compila la app en tu Mac, la copia a `/Applications` y la abre (ver "Instalar en otra Mac").

## Compilar e instalar

```sh
./build-app.sh            # compila en release y arma build/YTTranscriber.app
open build/YTTranscriber.app

./build-app.sh --install  # además lo copia a /Applications
./build-app.sh --zip      # además genera build/YTTranscriber-<versión>.zip (ver "Instalar en otra Mac")
./package-source.sh       # genera build/YTTranscriber-fuente.zip para compilar en otra Mac
```

El script:

- usa siempre las Command Line Tools (`DEVELOPER_DIR=/Library/Developer/CommandLineTools`), aunque `xcode-select` apunte a Xcode. Para usar otro toolchain, exportá `DEVELOPER_DIR` antes de correrlo;
- corre `swift build -c release --arch arm64`;
- descarga yt-dlp y deno (versiones y hashes fijos al principio del script) en `build/vendor/`;
- genera el ícono (`scripts/make-icon.swift` → `iconutil`);
- arma `Contents/MacOS`, `Contents/Helpers`, `Contents/Info.plist` y `Contents/Resources`;
- firma con firma ad-hoc (`codesign --force --deep -s -`) y verifica la firma.

Para actualizar las herramientas incluidas, cambiá `YTDLP_VERSION`/`YTDLP_SHA256` o `DENO_VERSION`/`DENO_SHA256` en `build-app.sh`. Los hashes salen de `SHA2-256SUMS` (yt-dlp) y de `deno-aarch64-apple-darwin.zip.sha256sum` (deno) en cada release.

## Instalar en otra Mac

La forma que funciona es pasar el **código fuente** y compilarlo allá:

1. `./package-source.sh` genera `build/YTTranscriber-fuente.zip` (~36 KB), con el código, `instalar.sh` y un `LEEME.txt`.
2. En la otra Mac, se descomprime y se corre en la Terminal:
   ```sh
   bash ~/Downloads/YTTranscriber-fuente/instalar.sh
   ```
   El script verifica el chip y la versión de macOS, pide instalar las Command Line Tools si faltan (gratis; abre la ventana de Apple y espera), compila con `build-app.sh --install` y abre la app.

Así la app se compila en esa Mac, igual que en la de desarrollo, y no queda marcada como descargada.

`./build-app.sh --zip` sigue generando un zip con la app ya compilada, pero **en macOS 26.6 no abre en otra Mac**. Una app firmada ad-hoc y descargada (por WhatsApp, AirDrop, etc.) queda pausada al arrancar (`_dyld_start`) aunque se le quite la cuarentena. La única forma de distribuir un binario que abra en cualquier Mac es firmarlo con Developer ID y notarizarlo, lo que requiere una cuenta paga de Apple Developer.

El modelo de Whisper se descarga la primera vez que hace falta (~1,5 GB, con progreso).

Solo compilar, sin empaquetar:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release
```

## Tests

Las Command Line Tools traen `Testing.framework`, pero SwiftPM no lo encuentra solo, y el overlay `_Testing_Foundation` viene incompleto. Con estos flags funciona:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
  -Xswiftc -F$F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F$F -Xlinker -rpath -Xlinker $F
```

## Uso

- Al abrir la app, si hay una URL de YouTube en el portapapeles se pega sola. macOS puede pedir permiso para leer el portapapeles.
- **Transcribir** (o Enter) arranca el proceso. El estado pasa por *Buscando subtítulos* → *Descargando audio* → *Transcribiendo* (con progreso) → *Listo*.
- **Copiar** o **⌘⇧C** copia el texto completo. El texto también se puede seleccionar a mano.
- La primera vez que hace falta Whisper se descarga el modelo (~1,6 GB) en `~/Library/Application Support/YTTranscriber/whisper/`, con barra de progreso. Las siguientes veces solo se carga.

## Estructura

```
Package.swift
build-app.sh
instalar.sh                instalador para otra Mac (compila e instala)
package-source.sh          arma el zip con el código fuente
Resources/Info.plist
scripts/make-icon.swift
Resources/LEEME.txt        instrucciones del zip con la app compilada
Resources/LEEME-fuente.txt instrucciones del zip con el código fuente
Sources/TranscriberCore/   lógica sin UI: URL, parser VTT, yt-dlp, herramientas incluidas, procesos, caché
Sources/YTTranscriber/     app SwiftUI + WhisperService (WhisperKit)
Tests/TranscriberCoreTests/
```

## Borrar datos

```sh
rm -rf ~/Library/Caches/YTTranscriber                         # caché de transcripciones
rm -rf ~/Library/Application\ Support/YTTranscriber          # modelo de Whisper y herramientas
```

## Licencia

[MIT](LICENSE).
