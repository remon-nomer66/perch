import Testing

@testable import Perch

// The device scope is strict, by the user's own design: rules are written per model
// ("この機種ならこれ"), and even the "same" setting — an equaliser preset above all —
// means something different on another device. A rule pinned to a model must therefore
// never apply on any other; only an unscoped rule (the grandfathered nil) applies
// anywhere.

private func artistRule(
  _ name: String, scopedTo model: String?, noise: SoundRule.NoiseAction = .ambient,
  preset: UInt8? = nil
) -> SoundRule {
  var rule = SoundRule(trigger: .artist(name))
  rule.deviceModel = model
  rule.noise = noise
  rule.equalizerPreset = preset
  return rule
}

@Test("A rule pinned to another model never applies — not even its noise action")
func foreignScopeNeverMatches() {
  let rules = [artistRule("YOASOBI", scopedTo: "WH-1000XM6", preset: 0x33)]
  let context = RuleMatcher.Context(deviceModel: "WF-1000XM6", playingArtist: "YOASOBI")
  #expect(RuleMatcher.match(rules, in: context) == nil)
}

@Test("With a foreign-scope artist rule out of the way, the unscoped app rule wins")
func unscopedAppRuleWinsWhenArtistRuleIsForeign() {
  // The situation on the WF with a WH-made YOASOBI rule: the artist rule is gated
  // out, so the Spotify rule — noise cancelling and its equaliser — must apply.
  var appRule = SoundRule(trigger: .app("com.spotify.client"))
  appRule.noise = .noiseCancelling
  appRule.equalizerPreset = 0xA2
  let artist = artistRule("YOASOBI", scopedTo: "WH-1000XM6")
  let context = RuleMatcher.Context(
    deviceModel: "WF-1000XM6",
    playingBundleID: "com.spotify.client",
    playingArtist: "YOASOBI"
  )
  #expect(RuleMatcher.match([appRule, artist], in: context)?.id == appRule.id)
}

@Test("The same artist scoped per model applies each rule on its own model only")
func perModelRulesStayApart() {
  let onWH = artistRule("YOASOBI", scopedTo: "WH-1000XM6", preset: 0x33)
  let onWF = artistRule("YOASOBI", scopedTo: "WF-1000XM6", preset: 0xA1)
  let rules = [onWH, onWF]

  let wf = RuleMatcher.Context(deviceModel: "WF-1000XM6", playingArtist: "YOASOBI")
  #expect(RuleMatcher.match(rules, in: wf)?.id == onWF.id)

  let wh = RuleMatcher.Context(deviceModel: "WH-1000XM6", playingArtist: "YOASOBI")
  #expect(RuleMatcher.match(rules, in: wh)?.id == onWH.id)
}
