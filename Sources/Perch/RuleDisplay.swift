import Foundation

/// The words the rules screens put on a rule: what triggers it, what it changes, and the
/// device it is written for. Shared so the site/app list and the music list read alike.
@MainActor
enum RuleDisplay {
  static func triggerLabel(_ trigger: SoundRule.Trigger) -> String {
    switch trigger {
    case .site(let domain): domain
    case .app(let bundleID): SoundRule.appTitle(for: bundleID)
    case .artist(let name): name
    }
  }

  static func actionSummary(_ rule: SoundRule) -> String {
    var parts: [String] = []
    if rule.noise != .keep {
      parts.append("\(L("ノイキャン", "NC")): \(noiseLabel(rule.noise))")
    }
    if let preset = rule.equalizerPreset {
      parts.append("EQ: \(PresetDisplay.label(for: preset))")
    }
    if rule.listening != .keep {
      parts.append("\(L("モード", "Mode")): \(listeningLabel(rule.listening))")
    }
    return parts.isEmpty ? L("変更なし", "No changes") : parts.joined(separator: " / ")
  }

  static func noiseLabel(_ action: SoundRule.NoiseAction) -> String {
    switch action {
    case .keep: L("そのまま", "Keep")
    case .noiseCancelling: L("ノイズキャンセリング", "Noise Cancelling")
    case .ambient: L("外音取り込み", "Ambient Sound")
    case .off: L("オフ", "Off")
    }
  }

  static func listeningLabel(_ action: SoundRule.ListeningAction) -> String {
    switch action {
    case .keep: L("そのまま", "Keep")
    case .standard: L("標準", "Standard")
    case .backgroundMusic: L("BGM", "Background Music")
    case .cinema: L("シネマ", "Cinema")
    }
  }

  /// The device a rule is pinned to, for its row. A rule stored before device scope
  /// existed carries no model and applies everywhere; it says so.
  static func deviceScopeLabel(_ model: String?) -> String {
    model ?? L("すべての機種", "All devices")
  }
}

/// Reordering a rule within only the rules shown beside it, leaving rules of other kinds
/// where they are — the site/app list and the music list each order their own without
/// disturbing the other's priority. Pure, so the tests drive it directly.
enum RuleOrdering {
  static func moving(
    _ rules: [SoundRule], id: UUID, by offset: Int, within listed: [SoundRule]
  ) -> [SoundRule] {
    guard let here = listed.firstIndex(where: { $0.id == id }) else { return rules }
    let there = here + offset
    guard listed.indices.contains(there),
      let i = rules.firstIndex(where: { $0.id == listed[here].id }),
      let j = rules.firstIndex(where: { $0.id == listed[there].id })
    else { return rules }
    var reordered = rules
    reordered.swapAt(i, j)
    return reordered
  }
}
