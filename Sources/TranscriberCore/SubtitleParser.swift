import Foundation

/// Convierte subtítulos WebVTT en texto corrido, sin marcas de tiempo ni repeticiones.
public enum SubtitleParser {
    public static func plainText(fromVTT vtt: String) -> String {
        var lines: [String] = []
        let normalized = vtt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        for block in normalized.components(separatedBy: "\n\n") {
            let blockLines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = blockLines.firstIndex(where: { $0.contains("-->") }) else {
                // Encabezado WEBVTT, NOTE, STYLE, REGION o basura: se descarta.
                continue
            }
            for raw in blockLines[(timingIndex + 1)...] {
                let line = clean(raw)
                guard !line.isEmpty else { continue }
                // Los subtítulos automáticos repiten la línea anterior en cada cue ("rolling captions").
                if line == lines.last { continue }
                lines.append(line)
            }
        }
        return paragraphs(from: lines)
    }

    /// Quita tags inline (<c>, <00:00:01.000>, <i>…), entidades HTML y espacios sobrantes.
    static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        // "&amp;" va al final para no decodificar dos veces ("&amp;lt;" → "&lt;").
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&")
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Une las líneas y corta en párrafos al final de una oración cada ~600 caracteres.
    public static func paragraphs(from lines: [String], targetLength: Int = 600) -> String {
        var result: [String] = []
        var current = ""
        for line in lines {
            current += current.isEmpty ? line : " " + line
            if current.count >= targetLength, let last = current.last, ".!?…".contains(last) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.joined(separator: "\n\n")
    }
}
