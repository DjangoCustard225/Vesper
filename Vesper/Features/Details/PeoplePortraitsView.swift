import SwiftUI
import VesperCore

struct PeoplePortraitsView: View {
    private struct Person: Identifiable {
        let id: Int
        let name: String
        let subtitle: String?
        let portraitURL: URL
        let website: URL
    }
    private let people: [Person]
    private let nameLineLimit: Int
    private let isCrew: Bool
    @State private var selectedPerson: Person?
    @State private var failedPortraitURLs: Set<URL> = []
    let title: String
    init(people: [CastMember], title: String) {
        self.title = title
        self.nameLineLimit = 3
        self.isCrew = false
        self.people = people.compactMap { person in
            guard let portrait = person.portraitURL.flatMap({ try? AddonURL.http($0) }) else { return nil }
            return Person(id: person.id, name: person.name, subtitle: person.character, portraitURL: portrait, website: person.website)
        }
    }
    init(crew: [CrewMember], title: String = "Crew") {
        self.title = title
        self.nameLineLimit = 1
        self.isCrew = true
        self.people = crew.compactMap { person in
            guard let portrait = person.portraitURL.flatMap({ try? AddonURL.http($0) }) else { return nil }
            return Person(id: person.id, name: person.name, subtitle: person.jobs.isEmpty ? nil : person.jobs.joined(separator: " · "), portraitURL: portrait, website: person.website)
        }
    }
    private var visiblePeople: [Person] { people.filter { !failedPortraitURLs.contains($0.portraitURL) } }
    var body: some View {
        if !visiblePeople.isEmpty {
            portraits
                .sheet(item: $selectedPerson) { person in
                    CrewDetailsSheet(person: person)
                        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
        }
    }
    private var portraits: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(visiblePeople) { person in
                        Group {
                            if isCrew {
                                Button { selectedPerson = person } label: { portraitCard(person) }
                                    .accessibilityHint("Opens crew roles")
                            } else {
                                Link(destination: person.website) { portraitCard(person) }
                                    .accessibilityHint("Opens this person on TMDB")
                            }
                        }.buttonStyle(.plain).accessibilityElement(children: .combine)
                    }
                }.padding(.horizontal, 24)
            }.scrollIndicators(.hidden).appScrollEdges().padding(.horizontal, -24)
        }
    }
    private func portraitCard(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            CachedArtworkImage(url: person.portraitURL) { phase in
                Group {
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Circle().fill(Design.surface) }
                }.onChange(of: phase.error != nil) { _, failed in
                    if failed { failedPortraitURLs.insert(person.portraitURL) }
                }
            }.frame(width: 100, height: 100).clipShape(Circle()).accessibilityHidden(true)
            Text(person.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(nameLineLimit).truncationMode(.tail)
            if !isCrew, let subtitle = person.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }.frame(width: 110, alignment: .topLeading).contentShape(Rectangle())
    }

    private struct CrewDetailsSheet: View {
        @Environment(\.dismiss) private var dismiss
        let person: Person
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        CachedArtworkImage(url: person.portraitURL) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Circle().fill(Design.surface) }
                        }.frame(width: 144, height: 144).clipShape(Circle()).accessibilityHidden(true)
                        Text(person.name).font(.title2.bold())
                        if let roles = person.subtitle {
                            Text(roles).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
                }.appScrollEdges().navigationTitle("Crew").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }.fontDesign(.default)
        }
    }
}
