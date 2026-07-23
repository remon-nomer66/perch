import Foundation
import Testing

@testable import Perch

/// A defaults suite of its own per test, removed afterwards so nothing leaks into
/// the real preferences or a later run.
@MainActor
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
  let name = "PerchTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  try body(defaults)
}

@Test("Settings survive a relaunch through the same defaults")
@MainActor
func settingsPersistAcrossStores() {
  withDefaults { defaults in
    let store = AppSettingsStore(defaults: defaults)
    store.isNotchEnabled = false
    store.isVirtualNotchEnabled = false
    store.notchDisplayMode = .onHover
    store.isRulesEnabled = true
    var rule = SoundRule(trigger: .site("example.com"))
    rule.listening = .cinema
    store.rules = [rule]
    store.customBandSteps["160"] = [1, 2, 3]

    let reloaded = AppSettingsStore(defaults: defaults)
    #expect(reloaded.isNotchEnabled == false)
    #expect(reloaded.isVirtualNotchEnabled == false)
    #expect(reloaded.notchDisplayMode == .onHover)
    #expect(reloaded.isRulesEnabled)
    #expect(reloaded.rules == [rule])
    #expect(reloaded.customBandSteps["160"] == [1, 2, 3])
  }
}

@Test("First launch defaults: notch on, bar always shown, rules off")
@MainActor
func firstLaunchDefaults() {
  withDefaults { defaults in
    let store = AppSettingsStore(defaults: defaults)
    #expect(store.isNotchEnabled)
    // A Mac with no cutout gets a virtual one by default; the interface is meant for
    // everyone, not only notched hardware.
    #expect(store.isVirtualNotchEnabled)
    #expect(store.hidesNotchInFullScreen)
    #expect(store.notchDisplayMode == .always)
    #expect(!store.isRulesEnabled)
    #expect(store.rules.isEmpty)
  }
}

@Test("Rules that no longer decode are left on disk, not overwritten")
@MainActor
func unreadableRulesAreLeftInPlace() {
  withDefaults { defaults in
    let garbage = Data("not rules".utf8)
    defaults.set(garbage, forKey: "AppSettings.rules")

    let store = AppSettingsStore(defaults: defaults)
    // The store starts empty rather than crashing…
    #expect(store.rules.isEmpty)
    // …and the stored bytes stay exactly as they were: a future build that can read
    // them again must still find them.
    #expect(defaults.data(forKey: "AppSettings.rules") == garbage)
  }
}

@Test("A successful decode may be re-saved")
@MainActor
func readableRulesAreResaved() {
  withDefaults { defaults in
    var rule = SoundRule(trigger: .app("com.example.player"))
    rule.noise = .noiseCancelling
    let stored = try! JSONEncoder().encode([rule])
    defaults.set(stored, forKey: "AppSettings.rules")

    let store = AppSettingsStore(defaults: defaults)
    #expect(store.rules == [rule])
    let resaved = defaults.data(forKey: "AppSettings.rules")
    #expect(resaved != nil)
    let decoded = try? JSONDecoder().decode([SoundRule].self, from: resaved ?? Data())
    #expect(decoded == [rule])
  }
}

@Test("Legacy cinema sites fold into cinema site rules once")
@MainActor
func legacyCinemaSitesMigrate() {
  withDefaults { defaults in
    defaults.set(["example.com"], forKey: "AppSettings.cinemaSites")
    defaults.set(true, forKey: "AppSettings.cinemaAutoEnabled")

    let store = AppSettingsStore(defaults: defaults)
    #expect(store.rules.count == 1)
    #expect(store.rules.first?.trigger == .site("example.com"))
    #expect(store.rules.first?.listening == .cinema)
    #expect(store.isRulesEnabled)
    // The legacy keys are consumed; a second launch must not duplicate the rules.
    #expect(defaults.stringArray(forKey: "AppSettings.cinemaSites") == nil)
  }
}
