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
/// lease the guard lets go on its own and the field follows the device again.
///
/// The lease counts from the latest sign that the write it covers is still on its way,
/// not from the moment it was asked. Counted from the ask, a write queued behind two
/// stuck ones outlived its own lease before it ever started, and the refresh snapped
/// the control back to the device's old value while it waited. So every `begin`
/// renews the lease — a drag still moving keeps its field — and `renew` restarts it
/// as the write progresses: each time the chain ahead of it advances, when it starts,
/// and before its read-back.
struct AdjustmentGuard {
  /// Longer than the longest gap between two renewals, with room to spare. The chain
  /// advances, and a running write gets to its read-back, within the chain's limit;
  /// the margin covers the read-back itself.
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

  /// Restarts the lease for `token` from `now`, as the write it covers makes progress.
  /// Only the latest token renews, and only while it still holds: a write overtaken
  /// meanwhile, or one whose guard was already lifted, must not hold the field again.
  mutating func renew(_ token: Int, now: ContinuousClock.Instant = .now) {
    guard generation == token, heldUntil != nil else { return }
    heldUntil = now.advanced(by: lease)
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
