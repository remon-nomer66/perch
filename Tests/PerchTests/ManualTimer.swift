import Testing

/// Stands in for `Task.sleep` wherever a type takes its sleep as a parameter, so a test
/// decides when time passes. No sleep ends on its own: `fire` ends every one in
/// progress, as though each had run its full length, and nothing depends on how busy
/// the machine running the tests is.
@MainActor
final class ManualTimer {
  private var sleepers: [CheckedContinuation<Void, Never>] = []

  /// Sleeps in progress right now.
  var pending: Int { sleepers.count }

  func sleep(_ duration: Duration) async {
    await withCheckedContinuation { sleepers.append($0) }
  }

  /// Ends every sleep in progress.
  func fire() {
    let due = sleepers
    sleepers.removeAll()
    for sleeper in due { sleeper.resume() }
  }

  /// Fires until nothing sleeps any more, so no task is left suspended past its test.
  func drain() async {
    for _ in 0..<50 where pending > 0 {
      fire()
      await yieldToMainActor()
    }
  }
}

/// Yields to the tasks under test until `condition` holds, bounded so a broken one fails
/// its test instead of hanging it. The bound is a backstop, not a timing assumption:
/// running out of it is recorded as a failure, so a step the test relies on can never
/// be skipped silently.
@MainActor
func waitUntil(
  within limit: Duration = .seconds(2),
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: () -> Bool
) async {
  let deadline = ContinuousClock.now.advanced(by: limit)
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(2))
  }
  if !condition() {
    Issue.record("The awaited condition never held", sourceLocation: sourceLocation)
  }
}

/// Lets the main actor run what is queued on it — enough for a task just resumed to
/// reach its end — before a test asserts that something did *not* happen.
@MainActor
func yieldToMainActor() async {
  for _ in 0..<20 { await Task.yield() }
}
