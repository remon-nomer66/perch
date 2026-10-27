import Testing

@testable import Perch

@MainActor
private final class TerminationGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

@MainActor
@Test("Termination drains restoration before closing and replies once")
func terminationDrainsBeforeClosing() async {
  let restored = TerminationGate()
  let restoreStarted = TerminationGate()
  let stopStarted = TerminationGate()
  let stopped = TerminationGate()
  let completed = TerminationGate()
  let restoreDeadline = TerminationGate()
  let finalDeadline = TerminationGate()
  let sequence = TerminationSequence(
    restorationDeadline: { await restoreDeadline.wait() },
    completionDeadline: { await finalDeadline.wait() }
  )
  var events: [String] = []
  sequence.begin(
    restore: {
      events.append("restore")
      restoreStarted.open()
      await restored.wait()
      events.append("restored")
    },
    stop: {
      events.append("stop")
      stopStarted.open()
      await stopped.wait()
    },
    completion: { events.append("reply"); completed.open() }
  )
  sequence.begin(restore: { events.append("duplicate") }, stop: {}, completion: {})
  await restoreStarted.wait()
  #expect(events == ["restore"])
  restored.open()
  await stopStarted.wait()
  #expect(events == ["restore", "restored", "stop"])
  #expect(!sequence.hasCompleted)
  stopped.open()
  await completed.wait()
  #expect(events == ["restore", "restored", "stop", "reply"])
  #expect(sequence.hasCompleted)
  restoreDeadline.open()
  finalDeadline.open()
}

@MainActor
@Test("Restoration deadline starts shutdown even while restoration is blocked")
func terminationRestorationDeadlineCloses() async {
  let restored = TerminationGate()
  let restoreStarted = TerminationGate()
  let restoreDeadline = TerminationGate()
  let finalDeadline = TerminationGate()
  let completed = TerminationGate()
  let restoreExited = TerminationGate()
  let sequence = TerminationSequence(
    restorationDeadline: { await restoreDeadline.wait() },
    completionDeadline: { await finalDeadline.wait() }
  )
  var stops = 0
  var replies = 0
  sequence.begin(
    restore: {
      restoreStarted.open()
      await restored.wait()
      restoreExited.open()
    },
    stop: { stops += 1 },
    completion: { replies += 1; completed.open() }
  )
  await restoreStarted.wait()
  #expect(stops == 0)
  restoreDeadline.open()
  await completed.wait()
  #expect(stops == 1)
  #expect(replies == 1)
  restored.open()
  await restoreExited.wait()
  finalDeadline.open()
  #expect(stops == 1)
  #expect(replies == 1)
}

@MainActor
@Test("Final deadline replies even if transport close is blocked")
func terminationTransportDeadlineReplies() async {
  let stopped = TerminationGate()
  let stopStarted = TerminationGate()
  let restoreDeadline = TerminationGate()
  let finalDeadline = TerminationGate()
  let completed = TerminationGate()
  let sequence = TerminationSequence(
    restorationDeadline: { await restoreDeadline.wait() },
    completionDeadline: { await finalDeadline.wait() }
  )
  var stops = 0
  var replies = 0
  sequence.begin(
    restore: {},
    stop: {
      stops += 1
      stopStarted.open()
      await stopped.wait()
    },
    completion: { replies += 1; completed.open() }
  )
  await stopStarted.wait()
  #expect(replies == 0)
  finalDeadline.open()
  await completed.wait()
  #expect(stops == 1)
  #expect(replies == 1)
  stopped.open()
  restoreDeadline.open()
  sequence.begin(restore: {}, stop: { stops += 1 }, completion: { replies += 1 })
  #expect(stops == 1)
  #expect(replies == 1)
}
