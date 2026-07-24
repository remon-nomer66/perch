import Foundation

/// Turns the JSON from GitHub's `releases/latest` endpoint into a `ReleaseInfo`. Pure
/// and synchronous, so it is tested from a fixture without a network.
enum GitHubReleaseParser {
  enum ParseError: Error, Equatable {
    /// The JSON did not decode, `tag_name` did not read as a version, or the release
    /// page URL was missing or not https.
    case malformed
    /// The release is a draft or a pre-release: not an update to offer automatically.
    case notAStableRelease
  }

  private struct RawRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool?
    let prerelease: Bool?
    let assets: [RawAsset]?

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case draft, prerelease, assets
    }
  }

  private struct RawAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  static func parse(_ data: Data) throws -> ReleaseInfo {
    guard let raw = try? JSONDecoder().decode(RawRelease.self, from: data) else {
      throw ParseError.malformed
    }
    if raw.draft == true || raw.prerelease == true { throw ParseError.notAStableRelease }
    guard let version = SemanticVersion(raw.tagName),
      let releaseURL = Self.httpsURL(raw.htmlURL)
    else { throw ParseError.malformed }

    let asset = Self.preferredAsset(raw.assets ?? [])
    return ReleaseInfo(
      version: version,
      tagName: raw.tagName,
      releaseURL: releaseURL,
      downloadURL: asset.flatMap { Self.httpsURL($0.browserDownloadURL) },
      downloadName: asset?.name
    )
  }

  /// The `.dmg` if one is attached, otherwise a `.zip`, otherwise nothing.
  private static func preferredAsset(_ assets: [RawAsset]) -> RawAsset? {
    assets.first { $0.name.lowercased().hasSuffix(".dmg") }
      ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
  }

  /// Only https URLs are trusted; a non-https or unparseable link is dropped rather
  /// than handed to the browser.
  private static func httpsURL(_ string: String) -> URL? {
    guard let url = URL(string: string), url.scheme?.lowercased() == "https" else { return nil }
    return url
  }
}
