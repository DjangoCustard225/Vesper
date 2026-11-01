import SwiftUI

struct AboutDescriptionView: View {
    let title: String
    let description: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
                Text(description).font(.body).lineSpacing(5).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.appScrollEdges().fontDesign(.default)
    }
}
