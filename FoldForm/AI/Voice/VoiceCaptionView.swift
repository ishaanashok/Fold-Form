import SwiftUI

/// The live caption: what is being heard, then what was understood and done. It never takes touches,
/// so it can't get in the way of the model beneath it.
struct VoiceCaptionView: View {
    let phase: VoicePhase

    var body: some View {
        if let content {
            HStack(spacing: 10) {
                Image(systemName: content.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(content.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let detail = content.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("voiceCaption")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private struct Content {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String?
    }

    private var content: Content? {
        switch phase {
        case .idle:
            nil
        case .listening(let text):
            Content(symbol: "waveform", tint: .cyan, title: text.isEmpty ? "Listening…" : text)
        case .interpreting(let text):
            Content(symbol: "ellipsis", tint: .secondary, title: text, detail: "Working out what you mean")
        case .executing(let steps):
            Content(symbol: "hammer", tint: .cyan, title: steps.joined(separator: " · "))
        case .done(let summary):
            Content(symbol: "checkmark.circle.fill", tint: .green, title: summary)
        case .failed(let text, let message):
            Content(symbol: "exclamationmark.circle.fill", tint: .orange, title: message, detail: text.isEmpty ? nil : "“\(text)”")
        }
    }
}
