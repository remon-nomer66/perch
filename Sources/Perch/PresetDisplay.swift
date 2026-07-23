import TandemCore

/// Labels for the preset tiles and the rule pickers, following the interface
/// language. The documented table stays the single source of what an identifier
/// means — mapping is by name, never by identifier — and the names with a known
/// Japanese/English pair are shown in whichever language is chosen, in either
/// direction. Genre names (Rock, Jazz, …) are shared by both languages, as the
/// official app also shows them.
enum PresetDisplay {
  /// The documented names that differ between the two languages.
  private static let pairs: [(japanese: String, english: String)] = [
    ("オフ", "Off"),
    ("ゲーム", "Game"),
    ("カスタム", "Custom"),
  ]

  static func label(for identifier: UInt8, language: AppLanguage = L10n.language) -> String {
    localized(TandemEqualizerPresetNames.label(for: identifier), language: language)
  }

  /// A documented label in the given interface language. The language rides in as a
  /// parameter so tests can pin it without steering the process-wide global, which
  /// other suites read and write concurrently.
  static func localized(_ label: String, language: AppLanguage = L10n.language) -> String {
    let japanese = language == .japanese
    if let pair = pairs.first(where: { $0.japanese == label || $0.english == label }) {
      return japanese ? pair.japanese : pair.english
    }
    // The numbered user slots keep their numbering; only the word is translated.
    return japanese
      ? label.replacingOccurrences(of: "User ", with: "ユーザー ")
      : label.replacingOccurrences(of: "ユーザー ", with: "User ")
  }
}
