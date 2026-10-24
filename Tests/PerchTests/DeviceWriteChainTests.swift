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

@MainActor
@Test("A queued write hears every advance of the chain ahead of it, and none once it runs")
func queuedWriteHearsEachAdvance() async {
  let timer = ManualTimer()
  let first = StuckWrite()
  let second = StuckWrite()
  let probe = Probe()
  var chain = DeviceWriteChain(sleep: timer.sleep)
  chain.enqueue { await first.run() }
  chain.enqueue { await second.run() }
  // Joins once the first is already running, as a write asked mid-chain does.
  await waitUntil { timer.pending == 1 }
  chain.enqueue(whileQueued: { probe.heard += 1 }) { probe.started = true }

  await yieldToMainActor()
  #expect(probe.heard == 0)
  timer.fire()  // the first write is given up on; the second reaches the head
  await waitUntil { probe.heard == 1 && timer.pending == 1 }
  #expect(probe.heard == 1)
  timer.fire()  // and the second; the queued write itself starts
  await waitUntil { probe.started }
  await yieldToMainActor()
  #expect(probe.heard == 1)

  first.release()
  second.release()
  await timer.drain()
}

/// A write that does not return until released, each on its own stream: one stream
/// cannot be awaited from two tasks at once.
private struct StuckWrite {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream()
  }

  func run() async {
    for await _ in stream {}
  }

  func release() {
    continuation.finish()
  }
}

@MainActor
private final class Probe {
  var heard = 0
  var started = false
}

/// One guarded field, read at an instant the test sets — so how long the writes ahead
/// took is a step of the test, not a wait.
@MainActor
private final class Field {
  var adjustment = AdjustmentGuard(lease: .seconds(20))
  var now = ContinuousClock.now
  var heldWhenItsWriteStarted: Bool?
}

@MainActor
@Test("A write queued behind two stuck ones still finds its field guarded when it starts")
func guardOutlastsTwoStuckWrites() async {
  let timer = ManualTimer()
  let first = StuckWrite()
  let second = StuckWrite()
  var chain = DeviceWriteChain(limit: .seconds(15), sleep: timer.sleep)
  let field = Field()
  let start = field.now
  chain.enqueue { await first.run() }
  chain.enqueue { await second.run() }
  await waitUntil { timer.pending == 1 }

  // Asked at t=3s, behind two writes that will each be waited for the full limit: it
  // starts at t=30s. Counted from the ask alone, a 20s lease ran out at t=23s and the
  // refresh showed the device's old value for the last seven seconds of the wait.
  field.now = start.advanced(by: .seconds(3))
  let token = field.adjustment.begin(now: field.now)
  chain.enqueue(whileQueued: { field.adjustment.renew(token, now: field.now) }) {
    field.heldWhenItsWriteStarted = field.adjustment.isHolding(now: field.now)
  }

  field.now = start.advanced(by: .seconds(15))
  timer.fire()
  await waitUntil { timer.pending == 1 }
  field.now = start.advanced(by: .seconds(30))
  timer.fire()
  await waitUntil { field.heldWhenItsWriteStarted != nil }
  #expect(field.heldWhenItsWriteStarted == true)

  first.release()
  second.release()
  await timer.drain()
}

@Test("The limit leaves a full response deadline of margin over a merely slow write")
func limitOutlastsTheSessionDeadline() {
  // A merely slow write can take about two response deadlines — one read-back answered
  // just inside its deadline, then another that runs out and faults the session. It
  // must never be given up on, so the limit sits a whole deadline beyond that.
  #expect(DeviceWriteChain.defaultLimit >= SessionCoordinator.Timeouts().response * 3)
}
