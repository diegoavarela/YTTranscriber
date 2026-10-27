import SwiftUI
import TranscriberCore

struct ContentView: View {
    @State private var model = TranscriberViewModel()
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Pegá una URL de YouTube", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit { model.start() }
                Button("Transcribir") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase.isBusy || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            StatusView(phase: model.phase)

            if let title = model.title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                    if let transcript = model.transcript {
                        Text(originDescription(transcript))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView {
                Text(model.transcript?.text ?? "")
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Text("⌘⇧C para copiar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.copyTranscript()
                } label: {
                    Label(model.copied ? "¡Copiado!" : "Copiar",
                          systemImage: model.copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .frame(minWidth: 90)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .tint(model.copied ? .green : nil)
                .disabled(model.transcript?.text.isEmpty ?? true)
                .animation(.easeInOut(duration: 0.15), value: model.copied)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            model.updateToolsIfNeeded()
            urlFieldFocused = true
        }
        .task {
            await model.pasteURLFromClipboardIfPresent()
        }
    }

    private func originDescription(_ transcript: Transcript) -> String {
        var parts = ["Origen: \(transcript.source.label)"]
        if let language = transcript.language, !language.isEmpty {
            parts.append("Idioma: \(language)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct StatusView: View {
    let phase: Phase

    var body: some View {
        switch phase {
        case .idle:
            Text("Pegá una URL y presioná Transcribir.")
                .foregroundStyle(.secondary)
        case .updatingTools:
            indeterminate("Actualizando yt-dlp…")
        case .searchingSubtitles:
            indeterminate("Buscando subtítulos…")
        case .downloadingAudio(let fraction):
            if let fraction {
                determinate("Descargando audio", fraction)
            } else {
                indeterminate("Descargando audio…")
            }
        case .downloadingModel(let fraction):
            determinate("Descargando modelo Whisper (solo la primera vez)", fraction)
        case .loadingModel:
            indeterminate("Cargando modelo Whisper…")
        case .transcribing(let fraction):
            determinate("Transcribiendo", fraction)
        case .done(let fromCache):
            Label(fromCache ? "Listo (desde caché)" : "Listo", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func indeterminate(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    private func determinate(_ text: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(text)… \(Int((fraction * 100).rounded()))%")
            ProgressView(value: min(max(fraction, 0), 1))
        }
    }
}
