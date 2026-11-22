import SwiftUI

struct SubDLLanguagePicker: View {
    private let title: LocalizedStringKey
    @Binding private var selection: String

    private static let languages = [
        "en", "ar", "fa", "es", "fr", "de", "it", "pt", "ru", "hi", "ja", "ko", "zh", "tr", "nl", "pl", "sv",
        "da", "fi", "no", "el", "he", "id", "ms", "th", "vi", "uk", "ro", "hu", "cs",
    ]

    init(_ title: LocalizedStringKey, selection: Binding<String>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Set(Self.languages + [selection])).sorted(), id: \.self) { code in
                Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
            }
        }
    }
}
