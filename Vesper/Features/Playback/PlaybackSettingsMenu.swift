import SwiftUI
import UIKit

/// Native menu presentation with visibility callbacks so auto-hide cannot remove its anchor.
struct PlaybackSettingsMenu: UIViewRepresentable {
    let menu: UIMenu
    let presentationChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PlaybackMenuButton {
        let button = PlaybackMenuButton(type: .system)
        var configuration = UIButton.Configuration.clearGlass()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .white
        configuration.image = UIImage(
            systemName: "gearshape",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = "Playback settings"
        button.menu = menu
        button.presentationChanged = presentationChanged
        return button
    }

    func updateUIView(_ button: PlaybackMenuButton, context: Context) {
        button.presentationChanged = presentationChanged
        // Playback time updates continuously; leave the presented menu stable until it closes.
        if !button.isHeld { button.menu = menu }
    }
}

final class PlaybackMenuButton: UIButton {
    var presentationChanged: ((Bool) -> Void)?

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        presentationChanged?(true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        if let animator {
            animator.addCompletion { [weak self] in self?.presentationChanged?(false) }
        } else {
            presentationChanged?(false)
        }
    }
}
