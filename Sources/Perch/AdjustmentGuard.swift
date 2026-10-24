/// Guards one panel field against the periodic refresh while writes are in flight.
///
/// Consecutive writes to the same field overlap: were the guard a plain flag, the
/// first write's completion would lift it while the second is still waiting, and the
/// refresh would snap the control back to the device's lagging value. Each `begin`
/// issues a fresh token; only the latest token's holder may lift the guard.
///
/// The guard is also leased. A holder that never comes back — a write the transport
/// never completes, a drag whose release never arrives because the panel closed under
/// the finger — would otherwise keep the field frozen on its optimistic value for the
/// rest of the session, deaf to every change made on the headset itself. Past the
/// lease the guard lets go on its own and the field follows the device again. Every
/// `begin` renews it, so a drag that is still moving keeps its field.
struct AdjustmentGuard {
  /// Longer than the write chain's limit, with room to spare: a write queued behind
  /// one that never returns starts only once the chain gives up on that one, and its
  /// guard must still be holding when it does — else the refresh snaps the control
  /// back just before the write lands. The margin covers the write's own read-back.
  static let defaultLease: Duration = DeviceWriteChain.defaultLimit + .seconds(5)

  private let lease: Duration
  private var heldUntil: ContinuousClock.Instant?
  private var generation = 0

  init(lease: Duration = AdjustmentGuard.defaultLease) {
    self.lease = lease
  }

  func isHolding(now: ContinuousClock.Instant = .now) -> Bool {
    heldUntil.map { now < $0 } ?? false
  }

  /// Whether `token` is still the latest: a write that waited in line can tell it was
  /// overtaken by a newer value for the same field.
  func isCurrent(_ token: Int) -> Bool {
    generation == token
  }

  mutating func begin(now: ContinuousClock.Instant = .now) -> Int {
    generation += 1
    heldUntil = now.advanced(by: lease)
    return generation
  }

  /// Lifts the guard, unless a later `begin` has superseded this token.
  mutating func end(_ token: Int) {
    if generation == token { heldUntil = nil }
  }

  /// Lifts the guard now and invalidates every outstanding token.
  mutating func cancel() {
    generation += 1
    heldUntil = nil
  }
}
