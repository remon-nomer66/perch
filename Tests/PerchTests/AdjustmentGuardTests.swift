import Testing

@testable import Perch

// The guard that keeps the periodic refresh off a panel field while a write to it is
// in flight. Only the latest token's holder may lift it — and if no holder ever does
// (a write that never returns, a drag whose release never arrives), it must let go on
// its own rather than freeze the field for the rest of the session.

@Test("A begun guard holds until its token ends it")
func beginHoldsUntilEnd() {
  var adjustment = AdjustmentGuard()
  let start = ContinuousClock.now
  let token = adjustment.begin(now: start)
  #expect(adjustment.isHolding(now: start))
  adjustment.end(token)
  #expect(!adjustment.isHolding(now: start))
}

@Test("An overtaken token cannot lift the guard its successor holds")
func supersededTokenDoesNotLift() {
  var adjustment = AdjustmentGuard()
  let start = ContinuousClock.now
  let first = adjustment.begin(now: start)
  let second = adjustment.begin(now: start)
  #expect(!adjustment.isCurrent(first))
  #expect(adjustment.isCurrent(second))
  adjustment.end(first)
  #expect(adjustment.isHolding(now: start))
  adjustment.end(second)
  #expect(!adjustment.isHolding(now: start))
}

@Test("Cancelling lifts the guard and invalidates every outstanding token")
func cancelLiftsAndInvalidates() {
  var adjustment = AdjustmentGuard()
  let start = ContinuousClock.now
  let token = adjustment.begin(now: start)
  adjustment.cancel()
  #expect(!adjustment.isHolding(now: start))
  #expect(!adjustment.isCurrent(token))
}

@Test("A guard nobody lifts lets go on its own once its lease runs out")
func guardLapsesAfterTheLease() {
  var adjustment = AdjustmentGuard(lease: .seconds(10))
  let start = ContinuousClock.now
  _ = adjustment.begin(now: start)
  #expect(adjustment.isHolding(now: start.advanced(by: .seconds(9))))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(10))))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(60))))
}

@Test("Each begin renews the lease, so a drag still moving keeps its field")
func beginRenewsTheLease() {
  var adjustment = AdjustmentGuard(lease: .seconds(10))
  let start = ContinuousClock.now
  _ = adjustment.begin(now: start)
  _ = adjustment.begin(now: start.advanced(by: .seconds(8)))
  #expect(adjustment.isHolding(now: start.advanced(by: .seconds(15))))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(18))))
}

@Test("The lease outlasts the longest gap between two renewals")
func leaseOutlastsTheGapBetweenRenewals() {
  // A queued write's guard is renewed each time the chain advances, and a running
  // write's before its read-back. Either gap is at most the chain's limit; a lease
  // shorter than that would lapse while the write is merely waiting its turn.
  #expect(AdjustmentGuard.defaultLease > DeviceWriteChain.defaultLimit)
}

@Test("Renewing restarts the lease from the renewal")
func renewRestartsTheLease() {
  var adjustment = AdjustmentGuard(lease: .seconds(20))
  let start = ContinuousClock.now
  let token = adjustment.begin(now: start)
  adjustment.renew(token, now: start.advanced(by: .seconds(15)))
  #expect(adjustment.isHolding(now: start.advanced(by: .seconds(34))))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(35))))
}

@Test("An overtaken token cannot renew the lease its successor holds")
func staleTokenDoesNotRenew() {
  var adjustment = AdjustmentGuard(lease: .seconds(20))
  let start = ContinuousClock.now
  let first = adjustment.begin(now: start)
  _ = adjustment.begin(now: start)
  adjustment.renew(first, now: start.advanced(by: .seconds(15)))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(20))))
}

@Test("A guard already lifted is not revived by a late renewal")
func renewDoesNotReviveALiftedGuard() {
  var adjustment = AdjustmentGuard(lease: .seconds(20))
  let start = ContinuousClock.now
  let token = adjustment.begin(now: start)
  adjustment.end(token)
  adjustment.renew(token, now: start.advanced(by: .seconds(1)))
  #expect(!adjustment.isHolding(now: start.advanced(by: .seconds(2))))
}
