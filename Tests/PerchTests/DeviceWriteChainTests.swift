import TandemSession
import Testing

@testable import Perch

// Device writes land in the order they were asked, and none of them can hold the rest
// hostage: a write that never comes back is waited for only up to the chain's limit.

/// What the queued operations did, in the order they did it.
@MainActor
private final class Journal {
  var entries: [String] = []

  /// Yields to the queued tasks until `condition` holds, bounded so a broken chain
  /// fails the test instead of hanging it.
  func wait(within limit: Duration = .seconds(2), until condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
@Test("Writes land in the order they were asked, however long each takes")
func writesKeepTheirOrder() async {
  let journal = Journal()
  var chain = DeviceWriteChain()
  chain.enqueue {
    try? await Task.sleep(for: .milliseconds(40))
    journal.entries.append("slow")
  }
  chain.enqueue { journal.entries.append("quick") }
  await journal.wait { journal.entries.count == 2 }
  #expect(journal.entries == ["slow", "quick"])
}

@MainActor
@Test("A write that never returns holds the next one only up to the limit")
func stuckWriteIsGivenUpOn() async {
  let journal = Journal()
  let (stuck, release) = AsyncStream<Void>.makeStream()
  // Wide enough that the early look below lands inside it even on a loaded machine.
  var chain = DeviceWriteChain(limit: .milliseconds(300))
  chain.enqueue {
    for await _ in stuck {}
    journal.entries.append("stuck finished")
  }
  chain.enqueue { journal.entries.append("next") }

  // Still inside the limit: the stuck write keeps its place at the head.
  try? await Task.sleep(for: .milliseconds(20))
  #expect(journal.entries.isEmpty)

  await journal.wait { journal.entries.contains("next") }
  #expect(journal.entries == ["next"])

  // Given up on is not cancelled: a late finish still runs its tail — the read-back
  // and the guard it lifts.
  release.finish()
  await journal.wait { journal.entries.count == 2 }
  #expect(journal.entries == ["next", "stuck finished"])
}

@MainActor
@Test("A write that returns promptly does not make the next one wait out the limit")
func promptWriteFreesTheChainAtOnce() async {
  let journal = Journal()
  var chain = DeviceWriteChain(limit: .seconds(30))
  chain.enqueue { journal.entries.append("first") }
  chain.enqueue { journal.entries.append("second") }
  await journal.wait(within: .seconds(1)) { journal.entries.count == 2 }
  #expect(journal.entries == ["first", "second"])
}

@Test("The limit sits well past the session's own response deadline")
func limitOutlastsTheSessionDeadline() {
  // A merely slow write — queued behind the readings poll, or riding out one
  // unanswered read-back until the session faults it — must never be given up on.
  #expect(DeviceWriteChain.defaultLimit > SessionCoordinator.Timeouts().response)
}
