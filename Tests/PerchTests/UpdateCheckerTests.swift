import Foundation
import Testing

@testable import Perch

// MARK: - Test doubles

/// A fetcher that returns a fixed payload (or fails when none) and counts its calls, so
/// the throttle can be observed.
private actor CountingFetcher: ReleaseFetching {
  private(set) var callCount = 0
  private let data: Data?

  init(data: Data?) { self.data = data }

  func fetchLatestReleaseJSON() async throws -> Data {
    callCount += 1
    guard let data else { throw URLError(.notConnectedToInternet) }
    return data
  }
}

/// A fetcher that hands back queued results in order, for exercising success-then-
/// failure sequences.
private actor ScriptedFetcher: ReleaseFetching {
  private var responses: [Result<Data, any Error>]

  init(_ responses: [Result<Data, any Error>]) { self.responses = responses }

  func fetchLatestReleaseJSON() async throws -> Data {
    guard !responses.isEmpty else { throw URLError(.timedOut) }
    return try responses.removeFirst().get()
  }
}

private func releaseJSON(tag: String) -> Data {
  let dict: [String: Any] = [
    "tag_name": tag,
    "html_url": "https://github.com/owner/perch/releases/tag/\(tag)",
    "assets": [
      [
        "name": "Perch.dmg",
        "browser_download_url":
          "https://github.com/owner/perch/releases/download/\(tag)/Perch.dmg",
      ]
    ],
  ]
  return try! JSONSerialization.data(withJSONObject: dict)
}

/// A fresh defaults suite per test, torn down afterwards so nothing leaks into the real
/// preferences or another test.
@MainActor
private func withChecker(
  current: String? = "1.0.0",
  fetcher: any ReleaseFetching,
  throttleSeconds: TimeInterval = 24 * 60 * 60,
  now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) },
  _ body: (UpdateChecker, AppSettingsStore) async throws -> Void
) async rethrows {
  let name = "PerchUpdateTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defer { UserDefaults.standard.removePersistentDomain(forName: name) }
  let settings = AppSettingsStore(defaults: defaults)
  let checker = UpdateChecker(
    currentVersion: current.flatMap(SemanticVersion.init),
    fetcher: fetcher,
    settings: settings,
    throttleSeconds: throttleSeconds,
    now: now
  )
  try await body(checker, settings)
}

// MARK: - Manual check

@MainActor
@Test("A newer remote release is reported as available")
func reportsWhenNewer() async {
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v1.1.0"))) { checker, _ in
    await checker.checkNow()
    guard case .available(let info) = checker.status else {
      Issue.record("expected .available, got \(checker.status)")
      return
    }
    #expect(info.version == SemanticVersion("1.1.0"))
    #expect(info.downloadURL != nil)
  }
}

@MainActor
@Test("The same or an older remote release is up to date")
func reportsUpToDate() async {
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v1.0.0"))) { checker, _ in
    await checker.checkNow()
    #expect(checker.status == .upToDate)
  }
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v0.9.0"))) { checker, _ in
    await checker.checkNow()
    #expect(checker.status == .upToDate)
  }
}

@MainActor
@Test("A skipped version is not offered, but a later one is")
func honoursSkip() async {
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v1.1.0"))) { checker, settings in
    settings.skippedUpdateVersion = "v1.1.0"
    await checker.checkNow()
    #expect(checker.status == .upToDate)
  }
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v1.2.0"))) { checker, settings in
    settings.skippedUpdateVersion = "v1.1.0"
    await checker.checkNow()
    #expect(checker.status.availableRelease?.tagName == "v1.2.0")
  }
}

@MainActor
@Test("Skipping the available update records its tag and clears the offer")
func skipRecordsTag() async {
  await withChecker(fetcher: CountingFetcher(data: releaseJSON(tag: "v1.1.0"))) { checker, settings in
    await checker.checkNow()
    #expect(checker.status.availableRelease != nil)
    checker.skipAvailable()
    #expect(checker.status == .upToDate)
    #expect(settings.skippedUpdateVersion == "v1.1.0")
  }
}

@MainActor
@Test("A network failure on a manual check surfaces as a failure")
func manualFailureSurfaces() async {
  await withChecker(fetcher: CountingFetcher(data: nil)) { checker, _ in
    await checker.checkNow()
    #expect(checker.status == .failed(.offlineOrUnreachable))
  }
}

@MainActor
@Test("A malformed response surfaces as a malformed failure")
func malformedFailure() async {
  await withChecker(fetcher: CountingFetcher(data: Data("{}".utf8))) { checker, _ in
    await checker.checkNow()
    #expect(checker.status == .failed(.malformedResponse))
  }
}

@MainActor
@Test("A development build cannot check and says so")
func developmentBuildCannotCheck() async {
  await withChecker(current: nil, fetcher: CountingFetcher(data: releaseJSON(tag: "v1.1.0"))) {
    checker, _ in
    #expect(checker.canCheck == false)
    await checker.checkNow()
    #expect(checker.status == .failed(.developmentBuild))
  }
}

// MARK: - Background check throttle

@MainActor
@Test("A background check hits the network at most once per throttle window")
func backgroundCheckThrottles() async {
  var clock = Date(timeIntervalSince1970: 1_000_000)
  let fetcher = CountingFetcher(data: releaseJSON(tag: "v1.1.0"))
  await withChecker(fetcher: fetcher, throttleSeconds: 3600, now: { clock }) { checker, _ in
    await checker.backgroundCheckIfDue()  // first: nothing recorded yet → fetches
    #expect(await fetcher.callCount == 1)

    await checker.backgroundCheckIfDue()  // within the window → skipped
    #expect(await fetcher.callCount == 1)

    clock = clock.addingTimeInterval(3601)  // window elapsed → fetches again
    await checker.backgroundCheckIfDue()
    #expect(await fetcher.callCount == 2)
  }
}

@MainActor
@Test("Background checks are off when the setting is off")
func backgroundCheckRespectsToggle() async {
  let fetcher = CountingFetcher(data: releaseJSON(tag: "v1.1.0"))
  await withChecker(fetcher: fetcher) { checker, settings in
    settings.checksForUpdatesAtLaunch = false
    await checker.backgroundCheckIfDue()
    #expect(await fetcher.callCount == 0)
    #expect(checker.status == .idle)
  }
}

@MainActor
@Test("A background failure does not clobber a previously found update")
func backgroundFailureKeepsKnownUpdate() async {
  var clock = Date(timeIntervalSince1970: 1_000_000)
  let fetcher = ScriptedFetcher([
    .success(releaseJSON(tag: "v1.1.0")),
    .failure(URLError(.timedOut)),
  ])
  await withChecker(fetcher: fetcher, throttleSeconds: 3600, now: { clock }) { checker, _ in
    await checker.checkNow()  // finds the update
    #expect(checker.status.availableRelease?.tagName == "v1.1.0")

    clock = clock.addingTimeInterval(3601)
    await checker.backgroundCheckIfDue()  // fails silently
    #expect(checker.status.availableRelease?.tagName == "v1.1.0")
  }
}
