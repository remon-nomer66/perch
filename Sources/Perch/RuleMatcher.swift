import Foundation

/// Picks the rule that should hold from what is currently being listened to. Kept apart
/// from the Apple-Events loop that feeds it, so the priority order and the device gate are
/// the pure thing the tests drive directly — the way the noise and listening targets are.
enum RuleMatcher {
  /// Everything the choice is made from. The browser hosts and titles are read once per
  /// pass and handed in; the artist is the playing player's, when one plays.
  struct Context {
    var deviceModel: String?
    var playingBundleID: String?
    var playingArtist: String?
    var frontmostBundleID: String?
    var browserHosts: [String]
    var browserTitles: [String]

    init(
      deviceModel: String? = nil,
      playingBundleID: String? = nil,
      playingArtist: String? = nil,
      frontmostBundleID: String? = nil,
      browserHosts: [String] = [],
      browserTitles: [String] = []
    ) {
      self.deviceModel = deviceModel
      self.playingBundleID = playingBundleID
      self.playingArtist = playingArtist
      self.frontmostBundleID = frontmostBundleID
      self.browserHosts = browserHosts
      self.browserTitles = browserTitles
    }
  }

  /// The matching rule, or nil. Artist beats app beats site: the artist is the most
  /// specific thing about what is heard, so it wins wherever it can be told — over the app
  /// playing it and over any site. Within a tier the earlier rule in the list wins, as
  /// before. A rule scoped to a model is skipped on any other; an unscoped rule (the
  /// grandfathered nil) applies anywhere.
  static func match(_ rules: [SoundRule], in context: Context) -> SoundRule? {
    func deviceMatches(_ rule: SoundRule) -> Bool {
      rule.deviceModel == nil || rule.deviceModel == context.deviceModel
    }

    // The artist can be told from the playing player, or from a browser tab's title —
    // the video pages the player scripting APIs never see.
    var artistHaystacks = context.browserTitles
    if let playingArtist = context.playingArtist {
      artistHaystacks.insert(playingArtist, at: 0)
    }
    if let hit = rules.first(where: { rule in
      guard deviceMatches(rule), case .artist(let name) = rule.trigger else { return false }
      return artistHaystacks.contains { ArtistMatch.matches(registered: name, in: $0) }
    }) {
      return hit
    }

    return rules.first { rule in
      guard deviceMatches(rule) else { return false }
      switch rule.trigger {
      case .app(let bundleID):
        return context.playingBundleID == bundleID
          || (context.playingBundleID == nil && context.frontmostBundleID == bundleID)
      case .site(let domain):
        return context.playingBundleID == nil
          && SiteWatcher.matches(hosts: context.browserHosts, sites: [domain])
      case .artist:
        return false
      }
    }
  }
}
