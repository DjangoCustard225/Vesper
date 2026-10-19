import SwiftUI
import VesperCore

struct AppAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = info["CFBundleShortVersionString"] as? String ?? ""
        guard let build = info["CFBundleVersion"] as? String else { return release }
        return "\(release) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(AppIdentity.displayName, value: version)
                LabeledContent("Designed for", value: "iOS 27")
            }
            Section {
                NavigationLink("Credits") { CreditsView() }
                Link(
                    "Stremio add-on protocol",
                    destination: URL(
                        string: "https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md")!)
            }
        }.appScrollEdges().navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}

struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TMDBAttribution()
                VStack(alignment: .leading, spacing: 12) {
                    Text("TheTVDB").font(.headline)
                    Text("Optional TV show metadata and artwork provided by TheTVDB.")
                        .foregroundStyle(.secondary)
                    Link("TheTVDB", destination: URL(string: "https://thetvdb.com")!)
                }
                #if !VESPER_GO
                VStack(alignment: .leading, spacing: 12) {
                    Text("MPVKit").font(.headline)
                    Text("Built-in playback uses MPVKit’s libmpv, licensed under LGPL 3.0 or later.")
                        .foregroundStyle(.secondary)
                    Link("Source code", destination: URL(string: "https://github.com/mpvkit/MPVKit")!)
                    NavigationLink("License") { PlayerLicenseView(name: "MPVKit") }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("AetherEngine").font(.headline)
                    Text(
                        "AVPlayer playback uses AetherEngine, licensed under LGPL 3.0 with an App Store / DRM exception."
                    )
                    .foregroundStyle(.secondary)
                    Link(
                        "Source code",
                        destination: URL(string: "https://github.com/superuser404notfound/AetherEngine")!)
                    NavigationLink("Licenses") { PlayerLicenseView(name: "AetherEngine") }
                }
                #endif
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.appBackground().navigationTitle("Credits").navigationBarTitleDisplayMode(.inline)
    }
}

#if !VESPER_GO
private struct PlayerLicenseView: View {
    let name: String

    private var license: String {
        guard let url = Bundle.main.url(forResource: name + "-LICENSE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "License unavailable." }
        return text
    }

    var body: some View {
        ScrollView { Text(license).font(.footnote).textSelection(.enabled).padding(24) }
            .appBackground().navigationTitle(name + " License").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
