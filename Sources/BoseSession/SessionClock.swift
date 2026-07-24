import Foundation

/// A monotonic instant expressed as elapsed time since a clock's own origin.
///
/// The session reasons about timing entirely in these instants — the earliest a
/// frame may next be sent, when a response has waited too long — so that every
/// deadline runs on an injected `SessionClock` and a test can advance time by hand
/// instead of sleeping. The origin is per-clock and arbitrary; only differences
/// between instants from the *same* clock are meaningful.
public struct BmapInstant: Comparable, Hashable, Sendable {
  /// Elapsed time since the clock's origin.
  public let elapsed: Duration

  public init(elapsed: Duration) {
    self.elapsed = elapsed
  }

  public func advanced(by duration: Duration) -> BmapInstant {
    BmapInstant(elapsed: elapsed + duration)
  }

  /// The interval from this instant to a later one (negative if `other` is earlier).
  public func duration(to other: BmapInstant) -> Duration {
    other.elapsed - elapsed
  }

  public static func < (lhs: BmapInstant, rhs: BmapInstant) -> Bool {
    lhs.elapsed < rhs.elapsed
  }
}

/// The clock the session reads time from and sleeps against.
///
/// Abstracted so timing is testable: `SystemSessionClock` drives production off a
/// `ContinuousClock`, and `TestSessionClock` lets a test advance time deterministically
/// so the settle window, response timeouts, and drain idle can all be exercised without
/// waiting real time.
public protocol SessionClock: Sendable {
  /// The current instant on this clock.
  func now() -> BmapInstant
  /// Suspends until `deadline` is reached. Returns immediately if it has already
  /// passed. Throws `CancellationError` if the awaiting task is cancelled.
  func sleep(until deadline: BmapInstant) async throws
}

/// The production clock, backed by a monotonic `ContinuousClock`.
public struct SystemSessionClock: SessionClock {
  private let clock = ContinuousClock()
  private let origin: ContinuousClock.Instant

  public init() {
    origin = ContinuousClock().now
  }

  public func now() -> BmapInstant {
    BmapInstant(elapsed: origin.duration(to: clock.now))
  }

  public func sleep(until deadline: BmapInstant) async throws {
    let remaining = now().duration(to: deadline)
    guard remaining > .zero else { return }
    try await Task.sleep(for: remaining)
  }
}
