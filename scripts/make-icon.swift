// Dibuja el ícono de la app (1024×1024) y lo guarda como PNG.
// Uso: swift scripts/make-icon.swift <salida.png>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("uso: make-icon.swift <salida.png>\n".utf8))
    exit(1)
}

let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("no se pudo crear el contexto gráfico\n".utf8))
    exit(1)
}

NSGraphicsContext.current = context

// Fondo: squircle rojo con degradé (márgenes de la grilla de íconos de macOS).
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(red: 1.0, green: 0.30, blue: 0.27, alpha: 1),
    ending: NSColor(red: 0.80, green: 0.05, blue: 0.10, alpha: 1)
)?.draw(in: tilePath, angle: -90)

// Botón "play" blanco.
let play = NSBezierPath()
play.move(to: NSPoint(x: 400, y: 640))
play.line(to: NSPoint(x: 400, y: 384))
play.line(to: NSPoint(x: 620, y: 512))
play.close()
NSColor.white.setFill()
play.fill()

// Líneas de texto debajo, como una transcripción.
NSColor.white.withAlphaComponent(0.85).setFill()
for (index, width) in [420.0, 340.0].enumerated() {
    let y = 300 - CGFloat(index) * 70
    NSBezierPath(roundedRect: NSRect(x: (size - width) / 2, y: y, width: width, height: 34), xRadius: 17, yRadius: 17).fill()
}

NSGraphicsContext.current = nil

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("no se pudo codificar el PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("no se pudo escribir el PNG: \(error.localizedDescription)\n".utf8))
    exit(1)
}
