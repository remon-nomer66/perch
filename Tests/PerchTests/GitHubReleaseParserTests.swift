import Foundation
import Testing

@testable import Perch

/// Builds a `releases/latest`-shaped JSON payload. Asset names are derived from their
/// URL's last path component, mirroring how GitHub names them.
private func releaseJSON(
  tag: String,
  assetURLs: [String] = [
    "https://github.com/owner/perch/releases/download/x/Perch-1.1.0.dmg"
  ],
  draft: Bool = false,
  prerelease: Bool = false
) -> Data {
  let assets = assetURLs.map { url -> [String: Any] in
    ["name": URL(string: url)!.lastPathComponent, "browser_download_url": url]
  }
  let dict: [String: Any] = [
    "tag_name": tag,
    "html_url": "https://github.com/owner/perch/releases/tag/\(tag)",
    "draft": draft,
    "prerelease": prerelease,
    "assets": assets,
  ]
  return try! JSONSerialization.data(withJSONObject: dict)
}

@Test("A well-formed release parses to its version and page")
func parsesVersionAndPage() throws {
  let info = try GitHubReleaseParser.parse(releaseJSON(tag: "v1.1.0"))
  #expect(info.version == SemanticVersion("1.1.0"))
  #expect(info.tagName == "v1.1.0")
  #expect(info.releaseURL.absoluteString == "https://github.com/owner/perch/releases/tag/v1.1.0")
}

@Test("A .dmg asset is preferred over a .zip")
func prefersDmgOverZip() throws {
  let info = try GitHubReleaseParser.parse(
    releaseJSON(
      tag: "v1.1.0",
      assetURLs: [
        "https://github.com/owner/perch/releases/download/x/Perch-1.1.0.zip",
        "https://github.com/owner/perch/releases/download/x/Perch-1.1.0.dmg",
      ]
    )
  )
  #expect(info.downloadName == "Perch-1.1.0.dmg")
  #expect(info.downloadURL?.absoluteString.hasSuffix(".dmg") == true)
}

@Test("A release with no downloadable asset falls back to the page")
func fallsBackToPageWithoutAsset() throws {
  let info = try GitHubReleaseParser.parse(releaseJSON(tag: "v1.1.0", assetURLs: []))
  #expect(info.downloadURL == nil)
  #expect(info.bestDownloadURL == info.releaseURL)
}

@Test("Drafts and pre-releases are not offered")
func rejectsDraftsAndPreReleases() {
  #expect(throws: GitHubReleaseParser.ParseError.notAStableRelease) {
    try GitHubReleaseParser.parse(releaseJSON(tag: "v1.1.0", draft: true))
  }
  #expect(throws: GitHubReleaseParser.ParseError.notAStableRelease) {
    try GitHubReleaseParser.parse(releaseJSON(tag: "v1.1.0", prerelease: true))
  }
}

@Test("Malformed JSON and non-version tags throw")
func rejectsMalformed() {
  #expect(throws: GitHubReleaseParser.ParseError.malformed) {
    try GitHubReleaseParser.parse(Data("{}".utf8))
  }
  #expect(throws: GitHubReleaseParser.ParseError.malformed) {
    try GitHubReleaseParser.parse(releaseJSON(tag: "nightly"))
  }
}

@Test("A non-https release URL is rejected")
func rejectsNonHTTPS() {
  let dict: [String: Any] = [
    "tag_name": "v1.1.0",
    "html_url": "http://github.com/owner/perch/releases/tag/v1.1.0",
    "assets": [],
  ]
  let data = try! JSONSerialization.data(withJSONObject: dict)
  #expect(throws: GitHubReleaseParser.ParseError.malformed) {
    try GitHubReleaseParser.parse(data)
  }
}

@Test("A non-https asset URL is dropped but the release still parses")
func dropsNonHTTPSAsset() throws {
  let info = try GitHubReleaseParser.parse(
    releaseJSON(
      tag: "v1.1.0",
      assetURLs: ["http://github.com/owner/perch/releases/download/x/Perch-1.1.0.dmg"]
    )
  )
  #expect(info.downloadURL == nil)
}
