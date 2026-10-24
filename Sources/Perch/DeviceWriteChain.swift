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
@MainActor
struct DeviceWriteChain {
  /// Twice the session's own response deadline. A write that is merely slow — queued
  /// behind the readings poll, or riding out one unanswered read-back until the session
  /// faults it — finishes inside this, so only a write the session failed to bound at
  /// all is given up on.
  nonisolated static let defaultLimit: Duration = SessionCoordinator.Timeouts().response * 2

  private static let log = Logger(subsystem: "dev.perch.mac", category: "DeviceWrite")

  private let limit: Duration
  private let sleep: @MainActor (Duration) async -> Void
  private var tail: Task<Void, Never>?

  /// `sleep` times the limit; tests pass one they advance by hand, so whether a write
  /// was given up on never depends on how busy the machine running them is.
  init(
    limit: Duration = DeviceWriteChain.defaultLimit,
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.limit = limit
    self.sleep = sleep
  }

  mutating func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = tail
    let limit = self.limit
    let sleep = self.sleep
    tail = Task { @MainActor in
      await previous?.value
      await Self.run(operation, within: limit, sleep: sleep)
    }
  }

  /// Returns once `operation` finishes or `limit` passes, whichever comes first.
  private static func run(
    _ operation: @escaping @MainActor () async -> Void,
    within limit: Duration,
    sleep: @escaping @MainActor (Duration) async -> Void
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
        log.error(
          "A device write did not return within \(limit.components.seconds, privacy: .public) s; the writes behind it go ahead"
        )
      }
    }
    await finish.wait()
    deadline.cancel()
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
