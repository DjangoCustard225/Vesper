import SwiftUI
import VesperCore

struct DownloadTransferRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicType
    let record: DownloadRecord
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicType.isAccessibilitySize {
                Artwork(
                    url: store.downloads.localArtwork(record.media.poster, record: record)?.absoluteString
                        ?? record.media.poster
                )
                .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            }
            DownloadTransferSummary(record: record, title: record.media.name, subtitle: record.subtitle)
            DownloadTransferAction(record: record)
        }.padding(.vertical, 6)
    }
}

struct DownloadTransferSummary: View {
    @Environment(AppStore.self) private var store
    let record: DownloadRecord
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let subtitle, subtitle != title {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            DownloadTransferProgress(record: record, compact: true)
            if let message = DownloadTransferPresentation(record: record).supportingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Only the active transfer's speed and ETA tick. Artwork and the surrounding list remain static.
struct DownloadTransferProgress: View {
    @Environment(AppStore.self) private var store
    let record: DownloadRecord
    var compact = false
    private var progress: DownloadProgress { store.downloads.progress(for: record) }
    private var presentation: DownloadTransferPresentation { .init(record: record) }
    private var fraction: Double? {
        presentation.fraction(bytes: progress.bytes, total: progress.total, work: progress.work)
    }
    private var running: Bool {
        record.phase == .downloading && progress.work == nil && record.message == nil
    }
    private var size: String? {
        let bytes = record.phase == .completed ? record.receivedBytes : progress.bytes
        let total = record.phase == .completed ? record.receivedBytes : progress.total
        guard bytes > 0 || total != nil else { return nil }
        let written = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return total.map {
            written + " of " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? written
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    presentation.status(
                        networkAvailable: store.downloads.networkAvailable,
                        canTransfer: store.downloads.canTransfer, work: progress.work))
                Spacer(minLength: 8)
                if let fraction, record.phase != .completed {
                    Text(
                        Double(Int((fraction * 100).rounded(.down))) / 100,
                        format: .percent.precision(.fractionLength(0))
                    ).monospacedDigit()
                } else if record.phase == .completed {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                }
            }.font(compact ? .caption : .subheadline).foregroundStyle(.secondary)
            if record.phase != .completed {
                if let fraction {
                    ProgressView(value: fraction).tint(.primary).accessibilityLabel("Download progress")
                        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
                } else if record.phase == .preparing || record.phase == .downloading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(
                        "Preparing download")
                }
            }
            if let size {
                Text(size).font(compact ? .caption2 : .caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if running {
                DownloadTransferRate(progress: progress, compact: compact)
            }
        }
    }
}

private struct DownloadTransferRate: View {
    let progress: DownloadProgress
    let compact: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if progress.currentSpeed > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(speed)
                        Spacer(minLength: 8)
                        if let remaining { Text(remaining) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(speed)
                        if let remaining { Text(remaining) }
                    }
                }.font(compact ? .caption2 : .caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    private var speed: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(progress.currentSpeed, Double(Int64.max / 2))), countStyle: .file) + "/s"
    }
    private var remaining: String? {
        guard let seconds = progress.remaining, seconds.isFinite else { return nil }
        return seconds < 60
            ? "Less than a minute remaining" : "\(Int(min(seconds / 60, 99999))) min remaining"
    }
}

struct DownloadTransferAction: View {
    @Environment(AppStore.self) private var store
    let record: DownloadRecord
    var prominent = false
    var play: (() -> Void)? = nil
    @State private var choosingFile = false
    @State private var enteringPassword = false
    @State private var password = ""
    private var action: DownloadTransferPresentation.Action {
        DownloadTransferPresentation(record: record).action
    }
    private var button: some View {
        Button(action: perform) {
            Label(record.phase == .pausing ? "Pausing…" : action.title, systemImage: action.symbol)
                .frame(
                    maxWidth: prominent ? .infinity : nil, minHeight: prominent ? 24 : Design.minimumHitTarget
                )
        }
        .disabled(record.phase == .pausing || (action == .play && play == nil))
        .accessibilityLabel(action.title + " download")
    }
    var body: some View {
        Group {
            if prominent {
                button.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .foregroundStyle(.black)
            } else {
                button.labelStyle(.iconOnly).buttonStyle(.borderless).tint(.primary)
                    .frame(minWidth: Design.minimumHitTarget, minHeight: Design.minimumHitTarget)
            }
        }
        .sheet(isPresented: $choosingFile) {
            NavigationStack {
                List(record.usenetFiles ?? [], id: \.self) { name in
                    Button(name) {
                        store.downloads.selectUsenetFile(record.id, name: name); choosingFile = false
                    }
                }.navigationTitle("Choose Video").navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert("Archive Password", isPresented: $enteringPassword) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { password = "" }
            Button("Continue") {
                store.downloads.setArchivePassword(record.id, password: password); password = ""
            }.disabled(password.isEmpty)
        }
    }
    private func perform() {
        switch action {
        case .pause: store.downloads.requestPause(record.id)
        case .resume, .retry: store.downloads.requestResume(record.id)
        case .play: play?()
        case .chooseVideo: choosingFile = true
        case .enterPassword: enteringPassword = true
        }
    }
}
