import Testing

@testable import Perch

// MARK: - Normalization

@Test("A bare domain is kept as typed, lowercased")
@MainActor
func bareDomainNormalizes() {
  #expect(SiteWatcher.normalizedSite("Example.com") == "example.com")
  #expect(SiteWatcher.normalizedSite("  example.com  ") == "example.com")
}

@Test("A pasted URL keeps only its host")
@MainActor
func pastedURLKeepsHost() {
  #expect(SiteWatcher.normalizedSite("https://example.com/watch?v=1") == "example.com")
  #expect(SiteWatcher.normalizedSite("https://sub.example.com/path") == "sub.example.com")
}

@Test("A leading www. is dropped, from URLs and bare domains alike")
@MainActor
func leadingWWWIsDropped() {
  #expect(SiteWatcher.normalizedSite("https://www.example.com/watch") == "example.com")
  #expect(SiteWatcher.normalizedSite("www.example.com") == "example.com")
}

@Test("Port and userinfo are dropped from bare entries")
@MainActor
func portAndUserinfoAreDropped() {
  #expect(SiteWatcher.normalizedSite("example.com:8080") == "example.com")
  #expect(SiteWatcher.normalizedSite("user@example.com") == "example.com")
  #expect(SiteWatcher.normalizedSite("user:pass@example.com:8080/path") == "example.com")
  #expect(SiteWatcher.normalizedSite("https://user:pass@example.com:8080/x") == "example.com")
}

@Test("Hostless input is rejected")
@MainActor
func hostlessInputIsRejected() {
  #expect(SiteWatcher.normalizedSite("") == nil)
  #expect(SiteWatcher.normalizedSite("   ") == nil)
  #expect(SiteWatcher.normalizedSite("nodots") == nil)
  #expect(SiteWatcher.normalizedSite("two words.com") == nil)
}

@Test("www alone does not become a site")
@MainActor
func wwwAloneIsRejected() {
  // Stripped of its prefix nothing with a dot remains.
  #expect(SiteWatcher.normalizedSite("www.") == nil)
}

// MARK: - Matching

@Test("A registered domain matches itself and its subdomains, not lookalikes")
@MainActor
func domainMatchesItselfAndSubdomains() {
  #expect(SiteWatcher.matches(hosts: ["example.com"], sites: ["example.com"]))
  #expect(SiteWatcher.matches(hosts: ["video.example.com"], sites: ["example.com"]))
  #expect(!SiteWatcher.matches(hosts: ["badexample.com"], sites: ["example.com"]))
  #expect(!SiteWatcher.matches(hosts: ["example.com"], sites: ["other.com"]))
}

@Test("www on either side does not break the match")
@MainActor
func wwwOnEitherSideStillMatches() {
  // Browsers report the host as-is; rules stored by an earlier build may carry www.
  #expect(SiteWatcher.matches(hosts: ["www.example.com"], sites: ["example.com"]))
  #expect(SiteWatcher.matches(hosts: ["example.com"], sites: ["www.example.com"]))
}

@Test("An empty site never matches")
@MainActor
func emptySiteNeverMatches() {
  #expect(!SiteWatcher.matches(hosts: ["example.com"], sites: [""]))
  #expect(!SiteWatcher.matches(hosts: [], sites: ["example.com"]))
}

// MARK: - 「音を出しているブラウザ」への紐付け

@Test("A browser is audible through its helper processes")
@MainActor
func helperProcessesCountAsTheirBrowser() {
  // ブラウザの音は本体ではなくヘルパープロセスから出る。
  #expect(SiteWatcher.browserIsAudible(
    "com.google.Chrome", outputting: ["com.google.Chrome.helper"]))
  #expect(SiteWatcher.browserIsAudible(
    "com.microsoft.edgemac", outputting: ["com.microsoft.edgemac.helper.renderer"]))
  #expect(SiteWatcher.browserIsAudible(
    "com.google.Chrome", outputting: ["com.google.Chrome"]))
}

@Test("Safari is audible through the WebKit media processes")
@MainActor
func safariIsAudibleThroughWebKit() {
  // Safari の音声は WebKit の GPU プロセスから出る。
  #expect(SiteWatcher.browserIsAudible(
    "com.apple.Safari", outputting: ["com.apple.WebKit.GPU"]))
  #expect(SiteWatcher.browserIsAudible(
    "com.apple.Safari", outputting: ["com.apple.Safari"]))
}

@Test("An unrelated audible process does not make a browser audible")
@MainActor
func unrelatedProcessesDoNotCount() {
  #expect(!SiteWatcher.browserIsAudible(
    "com.google.Chrome", outputting: ["com.spotify.client", "com.apple.Music"]))
  #expect(!SiteWatcher.browserIsAudible("com.google.Chrome", outputting: []))
  // 前方一致は「.」区切りで行う。似た名前の別アプリを拾わない。
  #expect(!SiteWatcher.browserIsAudible(
    "com.google.Chrome", outputting: ["com.google.Chromecast"]))
}

// MARK: - タブの URL とタイトルのペア

@Test("A scripted entry splits at the first tab into host and title")
@MainActor
func tabPairSplitsAtTheFirstTab() {
  let pair = SiteWatcher.parseTabPair("https://www.youtube.com/watch?v=1\tYOASOBI - アイドル")
  #expect(pair.host == "www.youtube.com")
  #expect(pair.title == "YOASOBI - アイドル")
  // タイトル側のタブ文字は保たれる（最初のタブでだけ割る）。
  let tabbed = SiteWatcher.parseTabPair("https://example.com/\ttitle\twith tab")
  #expect(tabbed.title == "title\twith tab")
}

@Test("An entry without a URL is all title, with no host to judge by")
@MainActor
func tabPairWithoutURLIsAllTitle() {
  let pair = SiteWatcher.parseTabPair("YOASOBI - アイドル")
  #expect(pair.host == nil)
  #expect(pair.title == "YOASOBI - アイドル")
}

@Test("Search-engine hosts are recognised; content sites are not")
@MainActor
func searchHostsAreRecognised() {
  // 検索結果のタイトルは打ち込んだ語の残響 — アーティスト名が載っていても
  // 「聴いている」証拠にならない。
  #expect(SiteWatcher.isSearchHost("www.google.com"))
  #expect(SiteWatcher.isSearchHost("google.co.jp"))
  #expect(SiteWatcher.isSearchHost("search.yahoo.co.jp"))
  #expect(SiteWatcher.isSearchHost("search.brave.com"))
  #expect(SiteWatcher.isSearchHost("bing.com"))
  #expect(SiteWatcher.isSearchHost("www.bing.com"))
  #expect(SiteWatcher.isSearchHost("duckduckgo.com"))
  // 音を聴く場所は除外しない。
  #expect(!SiteWatcher.isSearchHost("www.youtube.com"))
  #expect(!SiteWatcher.isSearchHost("music.youtube.com"))
  #expect(!SiteWatcher.isSearchHost("www.nicovideo.jp"))
  #expect(!SiteWatcher.isSearchHost("open.spotify.com"))
  // Google の別サービスまで巻き込まない（検索の本体だけ）。
  #expect(!SiteWatcher.isSearchHost("mail.google.com"))
}
