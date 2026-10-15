import SwiftUI
import VesperCore

struct ErrorNotice: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(message).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red).accessibilityHidden(true)
            }.font(.subheadline).accessibilityLabel("Error. \(message)")
            if let retry { Button("Try again", action: retry).buttonStyle(.glass) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
