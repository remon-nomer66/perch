import Combine
import Foundation

/// Checks GitHub for a newer Perch release and holds the result for the settings view
/// and the menu item to show. The network, the clock, and the throttle are injected so
/// the whole flow is exercised in tests without any of them.
///
/// The check only ever reads a public release feed and opens the browser at the user's
/// click; it never downloads or installs anything, and nothing about the user leaves the
/// machine. Replacing the app in Applications keeps every setting, since those live in
/// the preferences domain outside the bundle — so there is no migration to do here.
@MainActor
final class UpdateChecker: ObservableObject {
  @Published private(set) var status: UpdateStatus = .idle

  /// The running build's version, or nil for a bare `swift run` binary that carries no
  /// version to compare against.
  private let currentVersion: SemanticVersion?
  private let fetcher: any ReleaseFetching
  private let settings: AppSettingsStore
  /// How long a background check waits before it is willing to hit the API again.
  private let throttleSeconds: TimeInterval
  private let now: () -> Date

  private var periodic: Task<Void, Never>?

  init(
    currentVersion: SemanticVersion?,
    fetcher: any ReleaseFetching,
    settings: AppSettingsStore,
    throttleSeconds: TimeInterval = 24 * 60 * 60,
    now: @escaping () -> Date = { Date() }
  ) {
    self.currentVersion = currentVersion
    self.fetcher = fetcher
    self.settings = settings
    self.throttleSeconds = throttleSeconds
    self.now = now
  }

  /// Whether a version comparison is even possible; false for a development build.
  var canCheck: Bool { currentVersion != nil }

  // MARK: - Scheduling

  /// Runs a check now if updates are on, a comparison is possible, and the throttle
  /// window has elapsed — then keeps re-checking on that cadence. Called once at launch;
  /// a login-item app may stay running for days, so the day rolling over still finds a
  /// release without a relaunch.
  func begin() {
    guard periodic == nil else { return }
    periodic = Task { [weak self] in
      while !Task.isCancelled {
        await self?.backgroundCheckIfDue()
        // Wake hourly to catch the day turning over; the throttle below is what
        // actually gates the network call, so this is not a busy loop.
        try? await Task.sleep(for: .seconds(60 * 60))
      }
    }
  }

  func stop() {
    periodic?.cancel()
    periodic = nil
  }

  // MARK: - Checks

  /// A background pass: silent, throttled, and a no-op when checking is off or not
  /// possible. A failure here leaves any existing result untouched rather than replacing
  /// it with an error the user never asked to see.
  func backgroundCheckIfDue() async {
    guard settings.checksForUpdatesAtLaunch, canCheck else { return }
    if let last = settings.lastUpdateCheck, now().timeIntervalSince(last) < throttleSeconds {
      return
    }
    await performCheck(surfaceProgressAndFailure: false)
  }

  /// The manual "check now" path: ignores the throttle, shows progress, and reports a
  /// failure so the button gives feedback.
  func checkNow() async {
    guard canCheck else {
      status = .failed(.developmentBuild)
      return
    }
    await performCheck(surfaceProgressAndFailure: true)
  }

  /// Stop offering the update now on screen; the next, higher version will surface again
  /// because the skip records this exact tag.
  func skipAvailable() {
    if case .available(let info) = status {
      settings.skippedUpdateVersion = info.tagName
    }
    status = .upToDate
  }

  private func performCheck(surfaceProgressAndFailure surface: Bool) async {
    guard let currentVersion else { return }
    let previous = status
    if surface { status = .checking }
    settings.lastUpdateCheck = now()
    do {
      let data = try await fetcher.fetchLatestReleaseJSON()
      let release = try GitHubReleaseParser.parse(data)
      if release.version > currentVersion, release.tagName != settings.skippedUpdateVersion {
        status = .available(release)
      } else {
        status = .upToDate
      }
    } catch {
      // A manual check tells the user what went wrong; a background check quietly keeps
      // whatever it knew before (a prior "available" must survive a later offline poll).
      status = surface ? .failed(Self.failure(for: error)) : previous
    }
  }

  private static func failure(for error: any Error) -> UpdateCheckFailure {
    error is GitHubReleaseParser.ParseError ? .malformedResponse : .offlineOrUnreachable
  }
}
