import Testing

@testable import TandemSession

private let epoch = SessionEpoch(1)
private let laterEpoch = SessionEpoch(2)
private let maximumAttempts = 3

private func started(at value: Int) -> SettingState<Int> {
  var setting = SettingState<Int>()
  setting.apply(read: value, epoch: epoch, current: epoch)
  return setting
}

/// Drives a change all the way to the point where it is waiting to be verified.
private func changing(from current: Int, to target: Int) -> SettingState<Int> {
  var setting = started(at: current)
  _ = setting.request(target, epoch: epoch)
  setting.markWritten()
  setting.markVerifying()
  return setting
}

// MARK: - Display

@Test func theControlFollowsTheRequestBeforeTheDeviceConfirms() {
  var setting = started(at: 10)
  #expect(setting.displayed == 10)

  _ = setting.request(20, epoch: epoch)
  #expect(setting.displayed == 20, "the control did not follow the request")
  #expect(setting.confirmed == 10, "an unconfirmed value was reported as confirmed")
}

@Test func anUnreadSettingHasNoValue() {
  let setting = SettingState<Int>()
  #expect(setting.displayed == nil)
  #expect(setting.freshness == .unknown)
}

// MARK: - Reads outside a change

@Test func aChangeMadeOnTheHeadphoneIsReflected() {
  var setting = started(at: 10)
  setting.apply(notification: 30, epoch: epoch, current: epoch)
  #expect(setting.confirmed == 30)
  #expect(setting.displayed == 30)
}

@Test func readsFromAnOldSessionAreIgnored() {
  var setting = started(at: 10)
  setting.apply(read: 99, epoch: epoch, current: laterEpoch)
  setting.apply(notification: 98, epoch: epoch, current: laterEpoch)
  #expect(setting.confirmed == 10, "a value from a dead session was accepted")
}

@Test func aNotificationDuringAChangeCannotConfirm() {
  var setting = changing(from: 10, to: 20)

  // Mid-change the device may report either value. Only the verification read
  // decides what is true.
  setting.apply(notification: 10, epoch: epoch, current: epoch)
  #expect(setting.confirmed == 10)
  #expect(setting.displayed == 20, "a mid-change notification disturbed the request")
  #expect(setting.isChanging)
}

// MARK: - Verification

@Test func aMatchingReadConfirmsTheChange() {
  var setting = changing(from: 10, to: 20)
  let outcome = setting.apply(verification: 20, maximumAttempts: maximumAttempts)

  #expect(outcome == .confirmed)
  #expect(setting.confirmed == 20)
  #expect(setting.desired == nil, "the request outlived its confirmation")
  #expect(!setting.isChanging)
  #expect(setting.freshness == .fresh)
}

@Test func aSlowDeviceIsGivenMoreThanOneChance() {
  var setting = changing(from: 10, to: 20)

  // A device that has taken the change but not yet applied it reads back as the
  // old value. Failing on the first mismatch would report a working change as
  // broken.
  #expect(setting.apply(verification: 10, maximumAttempts: maximumAttempts) == .retry)
  #expect(setting.isChanging)

  #expect(setting.apply(verification: 20, maximumAttempts: maximumAttempts) == .confirmed)
  #expect(setting.confirmed == 20)
}

@Test func aChangeThatNeverTakesAdoptsWhatTheDeviceActuallyHolds() {
  var setting = changing(from: 10, to: 20)

  for _ in 0..<(maximumAttempts - 1) {
    #expect(setting.apply(verification: 55, maximumAttempts: maximumAttempts) == .retry)
  }
  let outcome = setting.apply(verification: 55, maximumAttempts: maximumAttempts)

  #expect(outcome == .settled)
  // Neither 20 nor 10 is true. Showing the value that was actually read is the only
  // honest option.
  #expect(setting.confirmed == 55)
  #expect(setting.displayed == 55)
  #expect(!setting.isChanging)
}

@Test func aVerificationTimeoutLeavesTheValueUnknownRatherThanWrong() {
  var setting = changing(from: 10, to: 20)
  setting.verificationTimedOut()

  #expect(setting.confirmed == 10)
  #expect(setting.desired == nil)
  #expect(setting.freshness == .stale, "an unverified value was presented as current")
}

// MARK: - Queued changes

@Test func draggingKeepsOnlyTheLatestValue() {
  var setting = changing(from: 0, to: 1)

  for value in 2...9 {
    let result = setting.request(value, epoch: epoch)
    #expect(try! result.get() == nil, "a queued change was sent while one was in flight")
  }
  #expect(setting.queuedLatest == 9)
  #expect(setting.displayed == 9)
}

@Test func confirmingOneChangeDoesNotUndoTheQueuedOne() {
  var setting = changing(from: 0, to: 1)
  _ = setting.request(9, epoch: epoch)

  setting.apply(verification: 1, maximumAttempts: maximumAttempts)

  // The control must not snap back to 1 just because 1 was confirmed: 9 is what
  // the user is asking for and what is about to be sent.
  #expect(setting.displayed == 9)
  #expect(setting.confirmed == 1)
  #expect(setting.isChanging, "the queued change was dropped instead of started")
  #expect(setting.transaction?.requestedValue == 9)
}

@Test func aFailedChangeDoesNotDragTheQueuedOneAlongWithIt() {
  var setting = changing(from: 0, to: 1)
  _ = setting.request(9, epoch: epoch)

  setting.verificationTimedOut()

  // Sending another unverified value straight after one could not be verified
  // compounds the problem.
  #expect(setting.queuedLatest == nil)
  #expect(!setting.isChanging)
}

// MARK: - Recovery

@Test func anUnansweredWriteLeavesTheValueUnknownAndBlocksFurtherChanges() {
  var setting = changing(from: 10, to: 20)
  setting.writeWentUnanswered()

  #expect(setting.isRecovering)
  #expect(setting.freshness == .stale)
  #expect(setting.desired == nil, "an unconfirmed value stayed on screen")

  // The device may hold 10, 20, or something else. Writing again before finding
  // out would pile a second unknown on top of the first.
  let rejection = setting.request(30, epoch: laterEpoch)
  #expect(rejection == .failure(.recovering))
}

@Test func recoveryEstablishesTheRealValueOnAFreshSession() {
  var setting = changing(from: 10, to: 20)
  setting.writeWentUnanswered()
  setting.markRecoveryReading()
  setting.apply(recovery: 20)

  #expect(setting.confirmed == 20, "the write had in fact landed")
  #expect(setting.freshness == .fresh)
  #expect(!setting.isRecovering)

  let accepted = setting.request(30, epoch: laterEpoch)
  #expect((try? accepted.get()) != nil)
}

@Test func recoverySurvivesTheSessionThatCausedIt() {
  var setting = changing(from: 10, to: 20)
  setting.writeWentUnanswered()

  // Invalidation is exactly what recovery is waiting through; ending it here would
  // discard the record of a write whose effect is still unknown.
  setting.sessionInvalidated()
  #expect(setting.isRecovering, "recovery was cancelled by the disconnect it exists for")
}

@Test func givingUpOnRecoveryLeavesTheValueMarkedUnreliable() {
  var setting = changing(from: 10, to: 20)
  setting.writeWentUnanswered()
  setting.recoveryAbandoned()

  #expect(!setting.isRecovering)
  #expect(setting.freshness == .stale)
  #expect(setting.confirmed == 10, "an unverified value was adopted")
}

// MARK: - Session loss

@Test func losingTheSessionDropsUnconfirmedValues() {
  var setting = changing(from: 10, to: 20)
  _ = setting.request(30, epoch: epoch)

  setting.sessionInvalidated()

  #expect(setting.desired == nil)
  #expect(setting.queuedLatest == nil)
  #expect(!setting.isChanging)
  #expect(setting.confirmed == 10)
  #expect(setting.freshness == .stale)
}

// MARK: - Cancellation boundary

@Test func aChangeStopsBeingCancellableOnceItIsWritten() {
  var setting = started(at: 10)
  _ = setting.request(20, epoch: epoch)
  #expect(setting.transaction?.isCommitted == false)

  setting.markWritten()
  #expect(setting.transaction?.isCommitted == true, "a written change still looked cancellable")
}
