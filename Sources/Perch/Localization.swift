import Foundation

/// The interface language. An explicit choice kept across launches; before anyone has
/// chosen, the first launch follows the system language.
enum AppLanguage: String, CaseIterable {
  case japanese = "ja"
  case english = "en"

  static var systemDefault: AppLanguage {
    Locale.preferredLanguages.first?.hasPrefix("ja") == true ? .japanese : .english
  }

  /// The name shown in the language menu — each language in itself, so the menu is
  /// readable exactly by the person who needs to switch to it.
  var nativeName: String {
    switch self {
    case .japanese: "日本語"
    case .english: "English"
    }
  }
}

/// The current language, read by every `L(_:_:)` pair at render time.
///
/// Written only on the main thread (the settings store and the language menu) and read
/// while menus are built and views render — also the main thread. The unsafe marker
/// spares every small view helper from having to become @MainActor for one string.
enum L10n {
  nonisolated(unsafe) static var language: AppLanguage = .japanese
}

/// The Japanese/English pair inline at the point of use, so the string a screen shows
/// stays readable in the code that shows it.
func L(_ japanese: String, _ english: String) -> String {
  L10n.language == .japanese ? japanese : english
}
