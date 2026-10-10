import Foundation
import VesperCore

struct StreamOption: Identifiable {
    let id = UUID()
    let addonName: String
    let source: StreamSource
}

struct StreamResults {
    var options: [StreamOption] = []
    var failures: [String] = []
}


struct VideoSelection: Identifiable {
    let id: String
    let title: String?
    let embedded: [StreamSource]?
}
