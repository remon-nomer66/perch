import Foundation

/// A published GitHub release reduced to what the updater needs: its version, the page
/// a human reads, and the best asset to download.
struct ReleaseInfo: Equatable, Sendable {
  let version: SemanticVersion
  /// The tag as published (`"v1.1.0"`), kept verbatim so "skip this version" records
  /// exactly what the API returned.
  let tagName: String
  /// The release page (`html_url`) — the fallback when there is no downloadable asset.
  let releaseURL: URL
  /// The preferred downloadable asset (a `.dmg`, else a `.zip`), when the release
  /// attached one.
  let downloadURL: URL?
  let downloadName: String?

  /// Where "download" should send the user: the asset if there is one, else the page.
  var bestDownloadURL: URL { downloadURL ?? releaseURL }
}

/// Why an update check could not complete. Carried as a reason, not a finished
/// sentence, so the settings view localizes it at render and a language switch re-reads
/// it like every other string.
enum UpdateCheckFailure: Equatable, Sendable {
  /// The network could not be reached, or the server answered with an error status.
  case offlineOrUnreachable
  /// The running binary carries no version (a bare `swift run`), so there is nothing to
  /// compare a release against.
  case developmentBuild
  /// A response arrived but could not be read as a release.
  case malformedResponse
}

/// What the updater currently knows, for the settings UI and the menu item to render.
enum UpdateStatus: Equatable, Sendable {
  /// Not checked yet this session, or checking is off / not possible.
  case idle
  case checking
  /// The running build is the latest published release.
  case upToDate
  /// A newer release is available.
  case available(ReleaseInfo)
  /// The check could not complete.
  case failed(UpdateCheckFailure)

  var availableRelease: ReleaseInfo? {
    if case .available(let info) = self { return info }
    return nil
  }
}
