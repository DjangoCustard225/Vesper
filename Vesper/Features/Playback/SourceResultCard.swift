import SwiftUI
import VesperCore

struct SourceResultCard: View {
    let option: StreamOption
    let action: () -> Void
    var isDownloadMode = false
    var isInDownloads = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var lines: [String] {
        (option.source.description ?? option.source.title ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var title: String { option.displayName }

    private var summary: String {
        var parts = [
            option.source.label.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(
                separator: " · ")
        ]
        if let size = option.nzbRelease?.size ?? option.source.behaviorHints?.videoSize, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var transport: String {
        if option.source.nzbUrl != nil { return "Usenet · AVPlayer" }
        if option.source.infoHash != nil { return "Torrent" }
        if option.source.externalUrl != nil || option.source.ytId != nil { return "External" }
        return "Stream"
    }

    private var extraDetails: String {
        (lines.first == title ? Array(lines.dropFirst()) : lines).joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if !summary.isEmpty && summary != title {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                if !extraDetails.isEmpty {
                    Text(extraDetails).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                if let posted = option.nzbRelease?.posted {
                    Text(posted, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(transport).foregroundStyle(.white)
                    Text("·")
                    Text(option.addonName).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }.font(.subheadline).foregroundStyle(.secondary)
                if isDownloadMode && isInDownloads {
                    Text("In Downloads").font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading).padding(.vertical, 16).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Design.minimumHitTarget, alignment: .leading)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.22), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
            .accessibilityLabel(
                [title, option.source.label, option.source.detail, option.addonName].joined(separator: ", ")
            )
            .accessibilityValue(isInDownloads ? "In Downloads" : "")
            .accessibilityHint(
                isDownloadMode
                    ? "Downloads this source. Long press for its full name."
                    : "Plays this source. Long press for its full name and more options.")
    }
}
