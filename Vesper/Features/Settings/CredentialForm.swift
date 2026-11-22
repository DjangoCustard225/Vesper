import SwiftUI
import UIKit

/// A settings row naming a credential, opening a native sheet to edit it.
struct CredentialRow: View {
    let title: String
    @Binding var text: String
    var prompt = "Required"
    /// The page's save and verify, run when the sheet is confirmed.
    var commit: (() -> Void)? = nil
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityHint("Edits \(title)")
        .sheet(isPresented: $editing) {
            CredentialSheet(title: title, prompt: prompt, text: $text, commit: commit)
        }
    }
}

/// A native sheet holding one credential field. Its checkmark, or the keyboard's Done key, closes
/// the sheet and saves and verifies the page's credentials.
struct CredentialSheet: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var commit: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CredentialTextField(
                        prompt: prompt, text: $text, accessibilityLabel: title, onReturn: confirm
                    )
                    .frame(maxWidth: .infinity, minHeight: 22)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        commit == nil ? "Done" : "Save and Verify", systemImage: "checkmark", action: confirm)
                }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
    }

    private func confirm() {
        dismiss()
        commit?()
    }
}

/// The toolbar's save and verify checkmark, replaced by a spinner while verification runs.
struct SaveVerifyButton: View {
    let busy: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark")
            }
        }
        .accessibilityLabel(busy ? "Verifying" : "Save and Verify")
        .disabled(busy || disabled)
    }
}

/// A plain text field with its own caret colour and a width that always fills its row.
struct CredentialTextField: UIViewRepresentable {
    let prompt: String
    @Binding var text: String
    var accessibilityLabel: String?
    var onReturn: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .asciiCapable
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.textContentType = .none
        field.returnKeyType = .done
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = prompt
        field.accessibilityLabel = accessibilityLabel
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Set the caret colour outright: SwiftUI's tint does not always reach a UIKit field.
        field.tintColor = .label
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.text = text
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onReturn = onReturn
        if field.text != text { field.text = text }
    }

    /// Fill the row's width; without this a UIKit field can be laid out with no width at all,
    /// hiding its text and caret.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context)
        -> CGSize?
    {
        let height = max(field.intrinsicContentSize.height, 22)
        return CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onReturn: onReturn) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onReturn: (() -> Void)?
        init(text: Binding<String>, onReturn: (() -> Void)?) {
            self.text = text
            self.onReturn = onReturn
        }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            onReturn?()
            return true
        }
    }

}
