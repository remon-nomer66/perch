import TandemSession
import os

/// Device writes land in the order they were asked, and none can hold the rest hostage.
///
/// Each write is its own Task, and two independent Tasks can reach the session actor
/// in either order — a rule switch whose "restore the old value" landed *after* the
/// new rule's write was exactly that race. Every write hops onto the tail of the
/// previous one instead.
///
/// Waiting unconditionally made one write that never comes back — a channel write the
/// transport never completes — stall every write after it, and with them the
/// adjustment guards their completions lift: the panel stopped following the device
/// altogether. So a write is waited for at most `limit`; past it the chain moves on.
/// The abandoned write is not cancelled — the session does not observe cancellation,
/// and should it finish after all, its read-back and the guard it lifts still run —
/// it merely stops holding up the writes behind it.
///
/// Each time a write reaches the head, every write still queued behind it hears so
/// through its `whileQueued`. The chain advances at least once per `limit`, so a guard
/// renewed there never lapses while its write is merely waiting its turn, however
/// many stuck writes are ahead of it.
@MainActor
struct DeviceWriteChain {
  /// Three of the session's own response deadlines. A write that is merely slow can
  /// take about two — queued behind the readings poll, one read-back answered just
  /// inside its deadline and another that runs out until the session faults it — so
  /// the limit keeps a whole deadline of margin over that, and only a write the session
  /// failed to bound at all is given up on.
  nonisolated static let defaultLimit: Duration = SessionCoordinator.Timeouts().response * 3

  private static let log = Logger(subsystem: "dev.perch.mac", category: "DeviceWrite")

  private let limit: Duration
  private let sleep: @MainActor (Duration) async -> Void
  private var tail: Task<Void, Never>?
  /// Shared by every copy of the chain, as the tail is: they are all the one line.
  private let queued = QueuedWrites()

  /// `sleep` times the limit; tests pass one they advance by hand, so whether a write
  /// was given up on never depends on how busy the machine running them is.
  init(
    limit: Duration = DeviceWriteChain.defaultLimit,
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.limit = limit
    self.sleep = sleep
  }

  /// Queues `operation` behind every write asked before it. `whileQueued` runs each time
  /// a write ahead of it reaches the head, and never once `operation` has started.
  mutating func enqueue(
    whileQueued: (@MainActor () -> Void)? = nil,
    onTimeout: (@MainActor () -> Void)? = nil,
    _ operation: @escaping @MainActor () async -> Void
  ) {
    let previous = tail
    let limit = self.limit
    let sleep = self.sleep
    let queued = self.queued
    let place = queued.join(whileQueued)
    tail = Task { @MainActor in
      await previous?.value
      queued.reachHead(place)
      await Self.run(operation, within: limit, sleep: sleep, onTimeout: onTimeout)
    }
  }

  /// Returns once every write asked so far has finished or been given up on — the
  /// links run one after another, so the last one's end is everyone's. For tests.
  func settled() async {
    await tail?.value
  }

  /// Returns once `operation` finishes or `limit` passes, whichever comes first.
  private static func run(
    _ operation: @escaping @MainActor () async -> Void,
    within limit: Duration,
    sleep: @escaping @MainActor (Duration) async -> Void,
    onTimeout: (@MainActor () -> Void)?
  ) async {
    let finish = FirstFinish()
    Task { @MainActor in
      await operation()
      finish.signal()
    }
    // The deadline runs as its own task, so the very write being stuck cannot delay it.
    let deadline = Task { @MainActor in
      await sleep(limit)
      guard !Task.isCancelled else { return }
      if finish.signal() {
        onTimeout?()
        log.error(
          "A device write did not return within \(limit.components.seconds, privacy: .public) s; the writes behind it go ahead"
        )
      }
    }
    await finish.wait()
    deadline.cancel()
  }
}

/// The writes waiting their turn, and what each wants to hear while it waits.
@MainActor
private final class QueuedWrites {
  private var listeners: [Int: @MainActor () -> Void] = [:]
  private var nextPlace = 0

  /// Takes a place in line; `listener`, if any, hears every advance until that place
  /// reaches the head.
  func join(_ listener: (@MainActor () -> Void)?) -> Int {
    nextPlace += 1
    listeners[nextPlace] = listener
    return nextPlace
  }

  /// The write at `place` reached the head: it leaves the line, and every write still
  /// behind it hears the chain move.
  func reachHead(_ place: Int) {
    listeners[place] = nil
    for listener in listeners.values { listener() }
  }
}

/// Resolves a wait on whichever of its signals comes first; later signals are dropped.
@MainActor
private final class FirstFinish {
  private var isSignalled = false
  private var waiter: CheckedContinuation<Void, Never>?

  /// True for the first signal only.
  @discardableResult
  func signal() -> Bool {
    guard !isSignalled else { return false }
    isSignalled = true
    waiter?.resume()
    waiter = nil
    return true
  }

  func wait() async {
    guard !isSignalled else { return }
    await withCheckedContinuation { waiter = $0 }
  }
}
