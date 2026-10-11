import Foundation
import VesperCore

struct VideoSelection: Identifiable {
    let id: String
    let title: String?
    let embedded: [StreamSource]?
}
