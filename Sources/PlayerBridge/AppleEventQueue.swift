import Foundation
import os

/// Runs blocking Apple Events work on a private serial queue, off the main thread.
///
/// An Apple Event is synchronous: a target that stops answering holds the sending
/// thread until the event's own timeout, minutes away. Sent from the main thread that
/// wait is the whole app freezing, so every send crosses to this queue instead. The
/// serial ordering is also the thread-safety story for the objects doing the sending —
/// ScriptingBridge proxies and `NSAppleScript` are documented as not thread-safe, so
/// each work item creates its own, and they never outlive the item or meet another
/// thread.
public final class AppleEventQueue: Sendable {
  private let queue: DispatchQueue

  public init(label: String) {
    // The senders feed the panel and answer taps; below user-interactive, above
    // background housekeeping.
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }

  /// One periodic query's in-flight marker: claimed when a round is enqueued and
  /// freed when it finishes running, however long past its deadline that is. A round
  /// finding the gate claimed skips instead of piling up behind a stuck one, so a
  /// hung target costs one deadline, never a queue of them. Each periodic caller
  /// holds its own gate — two independent cadences must not skip for each other.
  public final class Gate: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    fileprivate func claim() -> Bool {
      claimed.withLock { busy in
        if busy { return false }
        busy = true
        return true
      }
    }

    fileprivate func free() {
      claimed.withLock { $0 = false }
    }
  }

  /// Answers `work` from the queue, or `fallback` when the answer cannot be had in
  /// time — the gate is still claimed by an earlier round, or `timeout` passes
  /// first. A late answer is dropped rather than delivered: the caller keeps its
  /// cadence, and the stuck work finishes unobserved, freeing the gate for the
  /// round after.
  public func perform<Value: Sendable>(
    gate: Gate,
    timeout: Duration = .seconds(2),
    fallback: Value,
    _ work: @escaping @Sendable () -> Value
  ) async -> Value {
    guard gate.claim() else { return fallback }
    return await withCheckedContinuation { continuation in
      let once = OnceResume(continuation)
      queue.async {
        let value = work()
        gate.free()
        once.resume(returning: value)
      }
      // The deadline runs as its own task so the very queue being stuck cannot
      // delay it.
      Task {
        try? await Task.sleep(for: timeout)
        once.resume(returning: fallback)
      }
    }
  }

  /// Fire-and-forget work whose only answer is the target doing it — a transport
  /// command. No gate: a tap should act, not skip. But it does go stale: if the queue
  /// is blocked by a hung query, taps pile up behind it, and when it finally clears —
  /// its own Apple Event timeout minutes away — every queued command would fire at once,
  /// a burst of play/pause toggles the wearer never asked for now. So each carries a
  /// short deadline and is dropped if it only reaches the front after it: a transport
  /// command that late is stale, and doing nothing is righter than a storm.
  public func post(staleAfter: Duration = .seconds(3), _ work: @escaping @Sendable () -> Void) {
    let deadline = ContinuousClock.now.advanced(by: staleAfter)
    queue.async {
      guard ContinuousClock.now < deadline else { return }
      work()
    }
  }
}

/// Resumes a continuation exactly once: whichever of the answer and the deadline
/// comes second finds the continuation already taken and is dropped.
private final class OnceResume<Value: Sendable>: Sendable {
  private let held: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

  init(_ continuation: CheckedContinuation<Value, Never>) {
    held = OSAllocatedUnfairLock(initialState: continuation)
  }

  func resume(returning value: Value) {
    let continuation = held.withLock { state -> CheckedContinuation<Value, Never>? in
      defer { state = nil }
      return state
    }
    continuation?.resume(returning: value)
  }
}
