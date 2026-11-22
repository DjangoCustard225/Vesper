import SwiftUI

/// All / Movies / Series, drawn as the system segmented control.
struct MediaTypePicker: View {
    @Binding var selection: String
    private static let options = [("All", "all"), ("Movies", "movie"), ("Series", "series")]

    var body: some View {
        Picker("Content type", selection: $selection) {
            ForEach(Self.options, id: \.1) { Text($0.0).tag($0.1) }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .frame(minHeight: Design.minimumHitTarget)
    }
}
