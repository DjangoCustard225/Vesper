import SwiftUI
import VesperCore

struct SourceResultCard: View {
    let option: StreamOption
    let play: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var lines: [String] {
        (option.source.description ?? option.source.title ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var title: String {
        let filename = option.source.behaviorHints?.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let filename, !filename.isEmpty { return filename }
        return lines.first ?? option.source.label.replacingOccurrences(of: "\n", with: " · ")
    }
    private var summary: String {
        var parts = [option.source.label.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " · ")]
        if let size = option.source.behaviorHints?.videoSize, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var transport: String {
        if option.source.infoHash != nil { return "Torrent" }
        if option.source.externalUrl != nil || option.source.ytId != nil { return "External" }
        return "Stream"
    }
    private var extraDetails: String {
        (lines.first == title ? Array(lines.dropFirst()) : lines).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if !summary.isEmpty && summary != title {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    if !extraDetails.isEmpty {
                        Text(extraDetails)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                    HStack(spacing: 6) {
                        Text(transport).foregroundStyle(.white)
                        Text("·")
                        Text(option.addonName).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }.font(.subheadline).foregroundStyle(.secondary)
                }.multilineTextAlignment(.leading).padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel([title, option.source.label, option.source.detail, option.addonName].joined(separator: ", "))
                .accessibilityHint("Plays this source. Long press for player choices.")
            Button(action: play) {
                Image(systemName: option.source.externalUrl != nil || option.source.ytId != nil ? "arrow.up.right" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
            }.buttonStyle(SourcePlayButtonStyle()).accessibilityLabel("Play \(option.source.label)")
        }
        .padding(.vertical, 16).padding(.horizontal, 12)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.22), lineWidth: 1) }
    }
}

private struct SourcePlayButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.14), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(configuration.isPressed ? 0.20 : 0.08), lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: configuration.isPressed)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}
