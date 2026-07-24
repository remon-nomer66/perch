import AppKit
import Foundation

/// One automation rule: while its source is what is being listened to, the chosen
/// settings hold; when it stops being, whatever the rule changed is put back.
///
/// Every field can also be "keep": a rule that only sets the listening mode must not
/// touch the equaliser of someone who tuned it by hand.
struct SoundRule: Codable, Equatable, Identifiable {
  /// What makes the rule active. A playing player beats open sites: with a video
  /// parked in a browser and music playing in Spotify, the ears are on Spotify.
  enum Trigger: Codable, Equatable {
    /// A site shown on any browser window's front tab, subdomains included —
    /// matched only while no player is playing.
    case site(String)
    /// An application: a scriptable player counts while it is the one playing, and
    /// any app counts while it is frontmost with no player playing.
    case app(String)
    /// An artist being listened to: matched when the registered name is found in what
    /// a player reports playing, or in a browser tab's title. Higher priority than a
    /// site or app, since it is the most specific thing about what is being heard.
    case artist(String)
  }

  enum NoiseAction: String, Codable, CaseIterable {
    case keep, noiseCancelling, ambient, off
  }

  enum ListeningAction: String, Codable, CaseIterable {
    case keep, standard, backgroundMusic, cinema
  }

  var id = UUID()
  var trigger: Trigger
  /// The device model this rule is written for, by its declared model name, or nil to
  /// apply on any device. New rules are pinned to the connected model — an equaliser
  /// preset is one device's own identifier and is meaningless on another. Nil is the
  /// grandfathered value of rules stored before this field existed: they keep applying
  /// everywhere, exactly as they did.
  var deviceModel: String?
  var noise: NoiseAction = .keep
  /// The preset identifier to select, nil to keep.
  var equalizerPreset: UInt8?
  var listening: ListeningAction = .keep

  /// The scriptable players, pinned first in the picker: for them "playing" is the
  /// signal, which is stronger than being frontmost. Computed rather than stored so
  /// the Music app's name follows the interface language.
  static var knownApps: [(bundleID: String, title: String)] {
    [
      ("com.spotify.client", "Spotify"),
      ("com.apple.Music", L("ミュージック", "Music")),
    ]
  }

  /// A display name for any bundle: the pinned players by their titles, everything
  /// else by what is installed under that identifier, the raw identifier as a last
  /// resort so a rule for an uninstalled app still shows something.
  @MainActor
  static func appTitle(for bundleID: String) -> String {
    if let known = knownApps.first(where: { $0.bundleID == bundleID }) { return known.title }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let bundle = Bundle(url: url)
    {
      return (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        ?? (bundle.infoDictionary?["CFBundleName"] as? String)
        ?? bundleID
    }
    return bundleID
  }
}
