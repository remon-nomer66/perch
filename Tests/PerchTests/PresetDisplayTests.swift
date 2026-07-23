import Testing

@testable import Perch

/// The language is passed explicitly: the process-wide `L10n.language` is written by
/// other suites running in parallel (`AppSettingsStore.init` sets it), so any test
/// steering the global races with them.
struct PresetDisplayTests {
  @Test("Documented pairs follow the interface language, both directions")
  func pairsFollowLanguage() {
    #expect(PresetDisplay.localized("オフ", language: .english) == "Off")
    #expect(PresetDisplay.localized("ゲーム", language: .english) == "Game")
    #expect(PresetDisplay.localized("カスタム", language: .english) == "Custom")
    // Already-English labels stay put.
    #expect(PresetDisplay.localized("Off", language: .english) == "Off")

    #expect(PresetDisplay.localized("オフ", language: .japanese) == "オフ")
    // The reverse direction: an English label turns Japanese.
    #expect(PresetDisplay.localized("Off", language: .japanese) == "オフ")
    #expect(PresetDisplay.localized("Game", language: .japanese) == "ゲーム")
    #expect(PresetDisplay.localized("Custom", language: .japanese) == "カスタム")
  }

  @Test("User slots translate their word and keep their number")
  func userSlotsKeepNumbering() {
    #expect(PresetDisplay.localized("ユーザー 1", language: .english) == "User 1")
    #expect(PresetDisplay.localized("ユーザー 5", language: .english) == "User 5")
    #expect(PresetDisplay.localized("User 1", language: .japanese) == "ユーザー 1")
    #expect(PresetDisplay.localized("ユーザー 3", language: .japanese) == "ユーザー 3")
  }

  @Test("Genre names and raw identifiers pass through in both languages")
  func genreNamesPassThrough() {
    #expect(PresetDisplay.localized("Rock", language: .english) == "Rock")
    #expect(PresetDisplay.localized("0x7F", language: .english) == "0x7F")
    #expect(PresetDisplay.localized("Rock", language: .japanese) == "Rock")
    #expect(PresetDisplay.localized("0x7F", language: .japanese) == "0x7F")
  }

  @Test("Identifier lookup goes through the documented table")
  func identifierLookupUsesTheTable() {
    #expect(PresetDisplay.label(for: 0x00, language: .english) == "Off")
    #expect(PresetDisplay.label(for: 0x01, language: .english) == "Rock")
    #expect(PresetDisplay.label(for: 0xA0, language: .english) == "Custom")
    #expect(PresetDisplay.label(for: 0x00, language: .japanese) == "オフ")
    #expect(PresetDisplay.label(for: 0xA1, language: .japanese) == "ユーザー 1")
  }
}
