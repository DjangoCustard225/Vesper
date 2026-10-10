import SwiftUI

struct AboutDescriptionView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let description: String
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.title2.bold())
                    Text(description).font(.body).lineSpacing(5).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.appScrollEdges().navigationTitle("About").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.fontDesign(.default)
    }
}
