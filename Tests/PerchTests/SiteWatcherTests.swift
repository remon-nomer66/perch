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
