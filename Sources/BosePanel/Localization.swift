import Foundation

/// The interface language for the Bose panel's user-facing strings.
///
/// A self-contained copy of the app's `L(_:_:)` convention so `BosePanel` builds as an
/// independent module (it cannot import the `Perch` executable where the app-wide one
/// lives). Stage 6 bridges `L10n.language` here to the app's language setting when the
/// panel is wired into `Perch`, so the two follow one toggle.
enum AppLanguage: String, CaseIterable {
  case japanese = "ja"
  case english = "en"

  static var systemDefault: AppLanguage {
    Locale.preferredLanguages.first?.hasPrefix("ja") == true ? .japanese : .english
  }
}

/// The current language, read by every `L(_:_:)` pair at render time. Written and read on
/// the main thread only (the panel renders there); the unsafe marker spares every small
/// view helper from becoming `@MainActor` for one string.
enum L10n {
  nonisolated(unsafe) static var language: AppLanguage = .japanese
}

/// The Japanese/English pair inline at the point of use, so the string a screen shows
/// stays readable in the code that shows it.
func L(_ japanese: String, _ english: String) -> String {
  L10n.language == .japanese ? japanese : english
}
