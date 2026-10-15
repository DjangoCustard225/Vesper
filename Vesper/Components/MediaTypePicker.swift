import SwiftUI
import UIKit

/// Native segmented selection with explicit contrast under the app's white accent.
struct MediaTypePicker: UIViewRepresentable {
    @Binding var selection: String
    private static let options = [("All", "all"), ("Movies", "movie"), ("Series", "series")]

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: Self.options.map { $0.0 })
        control.selectedSegmentTintColor = .white
        control.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        control.accessibilityLabel = "Content type"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.options.firstIndex { $0.1 == selection } ?? 0
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
        control.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: max(Design.minimumHitTarget, uiView.intrinsicContentSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) { self.selection = selection }

        @objc func changed(_ control: UISegmentedControl) {
            guard MediaTypePicker.options.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = MediaTypePicker.options[control.selectedSegmentIndex].1
        }
    }
}
