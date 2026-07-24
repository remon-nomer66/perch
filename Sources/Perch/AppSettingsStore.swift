import Foundation

/// How the closed notch presents itself while a device is connected.
enum NotchDisplayMode: String, CaseIterable {
  /// The compact bar with the name and charge stays visible.
  case always
  /// The bare notch. The compact bar appears while the pointer is on it, and for a
  /// few seconds when a device connects.
  case onHover
}

/// How the app behaves, as opposed to how the notch is drawn — the drawing sizes live
/// in `NotchAppearanceStore`. Kept across launches.
@MainActor
final class AppSettingsStore: ObservableObject {
  @Published var isNotchEnabled: Bool {
    didSet { defaults.set(isNotchEnabled, forKey: Keys.notchEnabled) }
  }

  /// Put a notch on a Mac that has none, so its intuitive interface is reachable there
  /// too. Only ever consulted on a display without a real cutout; where one exists the
  /// hardware notch is used and this is moot.
  @Published var isVirtualNotchEnabled: Bool {
    didSet { defaults.set(isVirtualNotchEnabled, forKey: Keys.virtualNotchEnabled) }
  }

  /// Step aside while the notch screen is taken full screen: the menu bar hides
  /// there, and the bar would hover over the movie otherwise.
  @Published var hidesNotchInFullScreen: Bool {
    didSet { defaults.set(hidesNotchInFullScreen, forKey: Keys.hideInFullScreen) }
  }

  @Published var notchDisplayMode: NotchDisplayMode {
    didSet { defaults.set(notchDisplayMode.rawValue, forKey: Keys.displayMode) }
  }

  /// The interface language. `L10n.language` is kept in step here so every `L(_:_:)`
  /// pair reads the new language on its next render.
  @Published var language: AppLanguage {
    didSet {
      defaults.set(language.rawValue, forKey: Keys.language)
      L10n.language = language
    }
  }

  /// Apply the matching rule's settings while its source is being listened to, and
  /// put back whatever the rule changed when it stops.
  @Published var isRulesEnabled: Bool {
    didSet { defaults.set(isRulesEnabled, forKey: Keys.rulesEnabled) }
  }

  @Published var rules: [SoundRule] {
    didSet { saveRules() }
  }

  /// The band curves the user has dragged, by editable preset identifier. The device
  /// keeps its own copy; this one survives the device being adjusted from elsewhere.
  @Published var customBandSteps: [String: [Int]] {
    didSet { defaults.set(customBandSteps, forKey: Keys.customBands) }
  }

  private let defaults: UserDefaults

  private enum Keys {
    static let notchEnabled = "AppSettings.notchEnabled"
    static let virtualNotchEnabled = "AppSettings.virtualNotchEnabled"
    static let hideInFullScreen = "AppSettings.hidesNotchInFullScreen"
    static let displayMode = "AppSettings.notchDisplayMode"
    static let language = "AppSettings.language"
    static let rulesEnabled = "AppSettings.rulesEnabled"
    static let rules = "AppSettings.rules"
    static let customBands = "AppSettings.customBandSteps"
    // The first, cinema-only shape of the feature; folded into rules on launch.
    static let legacyCinemaEnabled = "AppSettings.cinemaAutoEnabled"
    static let legacyCinemaSites = "AppSettings.cinemaSites"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // The notch is the app's face; it starts on and stays on until switched off.
    isNotchEnabled = defaults.object(forKey: Keys.notchEnabled) as? Bool ?? true
    // A Mac with no cutout gets one made for it by default: the whole point is that the
    // notch interface should be there for everyone, not only notched hardware.
    isVirtualNotchEnabled = defaults.object(forKey: Keys.virtualNotchEnabled) as? Bool ?? true
    // Following the menu bar out of the way is what full screen means; staying put
    // is the opt-out.
    hidesNotchInFullScreen = defaults.object(forKey: Keys.hideInFullScreen) as? Bool ?? true
    // The bar being visible is how the app has always looked; quieting it is a choice.
    notchDisplayMode =
      defaults.string(forKey: Keys.displayMode).flatMap(NotchDisplayMode.init) ?? .always

    let language =
      defaults.string(forKey: Keys.language).flatMap(AppLanguage.init) ?? .systemDefault
    self.language = language
    // didSet does not fire during init; the global must still learn the stored choice
    // before the first menu or view is built.
    L10n.language = language

    var storedRules: [SoundRule] = []
    // Stored rules that no longer decode are left in place rather than replaced:
    // writing the empty fallback over them would destroy data a future build might
    // still read. Only a successful decode — or no data at all — may be re-saved.
    var storedRulesAreUnreadable = false
    if let data = defaults.data(forKey: Keys.rules) {
      if let decoded = try? JSONDecoder().decode([SoundRule].self, from: data) {
        storedRules = decoded
      } else {
        storedRulesAreUnreadable = true
      }
    }
    var enabled = defaults.object(forKey: Keys.rulesEnabled) as? Bool ?? false

    // Sites registered under the cinema-only version become cinema rules once.
    if !storedRulesAreUnreadable, storedRules.isEmpty,
      let sites = defaults.stringArray(forKey: Keys.legacyCinemaSites)
    {
      storedRules = sites.map { site in
        var rule = SoundRule(trigger: .site(site))
        rule.listening = .cinema
        return rule
      }
      enabled = defaults.object(forKey: Keys.legacyCinemaEnabled) as? Bool ?? enabled
      defaults.removeObject(forKey: Keys.legacyCinemaSites)
      defaults.removeObject(forKey: Keys.legacyCinemaEnabled)
    }

    isRulesEnabled = enabled
    rules = storedRules
    customBandSteps =
      defaults.dictionary(forKey: Keys.customBands) as? [String: [Int]] ?? [:]
    if !storedRulesAreUnreadable { saveRules() }
  }

  private func saveRules() {
    defaults.set(isRulesEnabled, forKey: Keys.rulesEnabled)
    guard let data = try? JSONEncoder().encode(rules) else { return }
    defaults.set(data, forKey: Keys.rules)
  }
}
