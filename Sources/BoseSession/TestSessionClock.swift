import Foundation

/// A `SessionClock` whose time only moves when a test tells it to.
///
/// Shipped in the target (not the test bundle) so both the scripted-session tests and
/// the stage-5 transport tests can drive session timing deterministically. `sleep`
/// registers the caller and suspends; `advance` moves time forward and resumes every
/// sleeper whose deadline has passed. Nothing waits real time, so timing behaviour —
/// the send settle window, response timeouts, the drain's idle cutoff — is exercised
/// in microseconds.
///
/// Thread-safe via a lock rather than an actor so `now()` stays synchronous, matching
/// the `SessionClock` protocol. Continuations are always resumed outside the lock to
/// avoid re-entering it from a resumed task.
public final class TestSessionClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Duration
  private var nextID: UInt64 = 0
  private var sleepers: [Sleeper] = []

  private struct Sleeper {
    let id: UInt64
    let deadline: Duration
    let continuation: CheckedContinuation<Void, Error>
  }

  public init(origin: Duration = .zero) {
    current = origin
  }

  public func now() -> BmapInstant {
    lock.lock()
    defer { lock.unlock() }
    return BmapInstant(elapsed: current)
  }

  public func sleep(until deadline: BmapInstant) async throws {
    let id: UInt64 = withLocked {
      let issued = nextID
      nextID &+= 1
      return issued
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // Resolve synchronously if the deadline is already in the past or the task is
        // already cancelled, so neither case leaves a sleeper stranded.
        let resolved: Result<Void, Error>? = withLocked {
          if Task.isCancelled { return .failure(CancellationError()) }
          if current >= deadline.elapsed { return .success(()) }
          sleepers.append(
            Sleeper(id: id, deadline: deadline.elapsed, continuation: continuation)
          )
          return nil
        }
        if let resolved { continuation.resume(with: resolved) }
      }
    } onCancel: {
      let continuation: CheckedContinuation<Void, Error>? = withLocked {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index).continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Moves time forward, resuming every sleeper now due. Resumptions happen after the
  /// lock is released so a resumed task can call back into the clock without deadlock.
  public func advance(by delta: Duration) {
    let due: [Sleeper] = withLocked {
      current += delta
      var ready: [Sleeper] = []
      var remaining: [Sleeper] = []
      for sleeper in sleepers {
        if sleeper.deadline <= current {
          ready.append(sleeper)
        } else {
          remaining.append(sleeper)
        }
      }
      sleepers = remaining
      return ready
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  /// Advances to an absolute instant. A no-op if the clock is already at or past it.
  public func advance(to instant: BmapInstant) {
    let delta = withLocked { instant.elapsed - current }
    guard delta > .zero else { return }
    advance(by: delta)
  }

  private func withLocked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
