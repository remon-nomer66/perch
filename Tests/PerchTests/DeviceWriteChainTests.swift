import TandemSession
import Testing

@testable import Perch

// Device writes land in the order they were asked, and none of them can hold the rest
// hostage: a write that never comes back is waited for only up to the chain's limit.
// The limit is timed by a manual timer, so "the limit passed" is a step of the test.

/// What the queued operations did, in the order they did it.
@MainActor
private final class Journal {
  var entries: [String] = []
}

@MainActor
@Test("Writes land in the order they were asked, however long each takes")
func writesKeepTheirOrder() async {
  let journal = Journal()
  let timer = ManualTimer()
  let (slow, release) = AsyncStream<Void>.makeStream()
  var chain = DeviceWriteChain(sleep: timer.sleep)
  chain.enqueue {
    for await _ in slow {}
    journal.entries.append("slow")
  }
  chain.enqueue { journal.entries.append("quick") }

  await waitUntil { timer.pending == 1 }
  #expect(journal.entries.isEmpty)
  release.finish()
  await waitUntil { journal.entries.count == 2 }
  #expect(journal.entries == ["slow", "quick"])
  await timer.drain()
}

@MainActor
@Test("A write that never returns holds the next one only up to the limit")
func stuckWriteIsGivenUpOn() async {
  let journal = Journal()
  let timer = ManualTimer()
  let (stuck, release) = AsyncStream<Void>.makeStream()
  var chain = DeviceWriteChain(sleep: timer.sleep)
  chain.enqueue {
    for await _ in stuck {}
    journal.entries.append("stuck finished")
  }
  chain.enqueue { journal.entries.append("next") }

  // The stuck write's deadline is running; until it passes, the stuck write keeps its
  // place at the head.
  await waitUntil { timer.pending == 1 }
  await yieldToMainActor()
  #expect(journal.entries.isEmpty)

  timer.fire()
  await waitUntil { journal.entries.contains("next") }
  #expect(journal.entries == ["next"])

  // Given up on is not cancelled: a late finish still runs its tail — the read-back
  // and the guard it lifts.
  release.finish()
  await waitUntil { journal.entries.count == 2 }
  #expect(journal.entries == ["next", "stuck finished"])
  await timer.drain()
}

@MainActor
@Test("A write that returns promptly does not make the next one wait out the limit")
func promptWriteFreesTheChainAtOnce() async {
  let journal = Journal()
  let timer = ManualTimer()
  var chain = DeviceWriteChain(sleep: timer.sleep)
  chain.enqueue { journal.entries.append("first") }
  chain.enqueue { journal.entries.append("second") }
  // The timer is never fired: had the chain waited out the limit, "second" never runs.
  await waitUntil { journal.entries.count == 2 }
  #expect(journal.entries == ["first", "second"])
  await timer.drain()
}

@Test("The limit leaves a full response deadline of margin over a merely slow write")
func limitOutlastsTheSessionDeadline() {
  // A merely slow write can take about two response deadlines — one read-back answered
  // just inside its deadline, then another that runs out and faults the session. It
  // must never be given up on, so the limit sits a whole deadline beyond that.
  #expect(DeviceWriteChain.defaultLimit >= SessionCoordinator.Timeouts().response * 3)
}
