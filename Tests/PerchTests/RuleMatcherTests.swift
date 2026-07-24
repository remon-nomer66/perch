import Testing

@testable import Perch

private func rule(
  _ trigger: SoundRule.Trigger,
  device: String? = nil
) -> SoundRule {
  var made = SoundRule(trigger: trigger)
  made.deviceModel = device
  return made
}

@Test("An artist rule wins over an app rule for the same player, whatever the list order")
func artistBeatsApp() {
  let rules = [
    rule(.app("com.spotify.client"), device: "WH-1000XM6"),
    rule(.artist("YOASOBI"), device: "WH-1000XM6"),
  ]
  let context = RuleMatcher.Context(
    deviceModel: "WH-1000XM6",
    playingBundleID: "com.spotify.client",
    playingArtist: "YOASOBI feat. 幾田りら"
  )
  #expect(RuleMatcher.match(rules, in: context)?.trigger == .artist("YOASOBI"))
}

@Test("A rule scoped to another model does not apply; a nil scope applies anywhere")
func deviceGate() {
  // The scope is strict by the user's own design: each model gets its own rules, and
  // an equaliser preset means something different per device.
  let scoped = [rule(.artist("YOASOBI"), device: "WH-1000XM6")]
  #expect(
    RuleMatcher.match(scoped, in: .init(deviceModel: "WF-1000XM6", playingArtist: "YOASOBI")) == nil
  )
  #expect(
    RuleMatcher.match(scoped, in: .init(deviceModel: "WH-1000XM6", playingArtist: "YOASOBI"))?
      .trigger == .artist("YOASOBI")
  )

  let unscoped = [rule(.artist("YOASOBI"), device: nil)]
  #expect(
    RuleMatcher.match(unscoped, in: .init(deviceModel: "some-other-model", playingArtist: "YOASOBI"))?
      .trigger == .artist("YOASOBI")
  )
}

@Test("An artist is matched from a browser tab title when no player is playing")
func artistFromBrowserTitle() {
  let rules = [rule(.artist("Fujii Kaze"))]
  let context = RuleMatcher.Context(browserTitles: ["Fujii Kaze - I Need U - YouTube"])
  #expect(RuleMatcher.match(rules, in: context)?.trigger == .artist("Fujii Kaze"))
}

@Test("While a player plays, an open tab naming another artist does not hijack the artist rule")
func aPlayingPlayerSilencesTabTitles() {
  // 聴いているのは Vaundy。どこかのウィンドウに YOASOBI のタブが開いているだけで
  // YOASOBI ルールに持っていかれてはいけない。
  let rules = [rule(.artist("YOASOBI"))]
  let context = RuleMatcher.Context(
    playingBundleID: "com.spotify.client",
    playingArtist: "Vaundy, Cory Wong",
    browserTitles: ["YOASOBI「アイドル」 - YouTube"]
  )
  #expect(RuleMatcher.match(rules, in: context) == nil)
}

@Test("A player playing without artist info still keeps tab titles out of it")
func aPlayerWithoutArtistInfoSilencesTabTitles() {
  // プレーヤーが鳴っている限り、タブのタイトルは「聴いているもの」の証拠にならない。
  let rules = [rule(.artist("YOASOBI"))]
  let context = RuleMatcher.Context(
    playingBundleID: "com.spotify.client",
    browserTitles: ["YOASOBI「アイドル」 - YouTube"]
  )
  #expect(RuleMatcher.match(rules, in: context) == nil)
}

@Test("The playing player's own artist still matches while tabs are open")
func thePlayingArtistStillMatches() {
  let rules = [rule(.artist("Vaundy"))]
  let context = RuleMatcher.Context(
    playingBundleID: "com.spotify.client",
    playingArtist: "Vaundy, Cory Wong",
    browserTitles: ["YOASOBI「アイドル」 - YouTube"]
  )
  #expect(RuleMatcher.match(rules, in: context)?.trigger == .artist("Vaundy"))
}

@Test("An artist rule wins over a site rule")
func artistBeatsSite() {
  let rules = [
    rule(.site("youtube.com")),
    rule(.artist("Fujii Kaze")),
  ]
  let context = RuleMatcher.Context(
    browserHosts: ["youtube.com"],
    browserTitles: ["Fujii Kaze - I Need U - YouTube"]
  )
  #expect(RuleMatcher.match(rules, in: context)?.trigger == .artist("Fujii Kaze"))
}

@Test("A playing player matches its app rule; a site rule waits until no player plays")
func appAndSiteTiers() {
  let rules = [
    rule(.app("com.spotify.client")),
    rule(.site("youtube.com")),
  ]
  #expect(
    RuleMatcher.match(
      rules,
      in: .init(playingBundleID: "com.spotify.client", browserHosts: ["youtube.com"])
    )?.trigger == .app("com.spotify.client")
  )
  #expect(
    RuleMatcher.match(rules, in: .init(browserHosts: ["youtube.com"]))?.trigger
      == .site("youtube.com")
  )
}

@Test("An app rule wins over a site rule, whatever the list order")
func appBeatsSiteWhateverTheOrder() {
  // Documented as artist > app > site — but a combined pass let the list order pick
  // the site rule whenever it sat higher. The app tier names what makes the sound
  // (or holds the foreground); the site tier only what some window shows.
  let rules = [
    rule(.site("youtube.com")),
    rule(.app("com.apple.Music")),
  ]
  let context = RuleMatcher.Context(
    frontmostBundleID: "com.apple.Music",
    browserHosts: ["youtube.com"]
  )
  #expect(RuleMatcher.match(rules, in: context)?.trigger == .app("com.apple.Music"))
}

@Test("With no player, a frontmost app matches its app rule")
func frontmostAppMatches() {
  let rules = [rule(.app("com.apple.Music"))]
  #expect(
    RuleMatcher.match(rules, in: .init(frontmostBundleID: "com.apple.Music"))?.trigger
      == .app("com.apple.Music")
  )
}

@Test("Nothing matches when no rule applies")
func noMatch() {
  let rules = [rule(.artist("YOASOBI")), rule(.app("com.spotify.client"))]
  #expect(
    RuleMatcher.match(
      rules,
      in: .init(playingArtist: "Someone Else", frontmostBundleID: "com.other")
    ) == nil
  )
}
