import Testing

@testable import TandemSession

private let deviceA = DeviceIdentity("device-a")
private let deviceB = DeviceIdentity("device-b")

private func state(
  _ phase: SessionState.Phase,
  target: DeviceIdentity? = deviceA,
  failureCount: Int = 0,
  attempt: ConnectionAttempt = ConnectionAttempt(0),
  isDefaultOutput: Bool = true
) -> SessionState {
  SessionState(
    phase: phase,
    target: target,
    failureCount: failureCount,
    attempt: attempt,
    isTargetDefaultOutput: isDefaultOutput
  )
}

private let policy = SessionPolicy(maximumFailureCount: 3)

// MARK: - Connection lifecycle

@Test func reachingUnverifiedResetsTheFailureBudget() {
  // An unverified device that connects successfully is a successful connection: a
  // headset that drops the channel on every wearing change would otherwise spend
  // the whole failure budget across hours of normal use and stick at exhausted.
  // The reset waits for the session to prove itself, so a session that fails before
  // then still counts — see `aSessionThatFaultsBeforeProvingStableExhaustsItsBudget`.
  let (unverified, _) = policy.reduce(
    state(.verifying, failureCount: 2),
    .verificationRejected
  )
  #expect(unverified.phase == .unverified)

  let (next, effects) = policy.reduce(unverified, .sessionProvedStable)
  #expect(next.phase == .unverified)
  #expect(next.failureCount == 0)
  #expect(effects.isEmpty)
}

@Test func verificationAloneDoesNotRestoreTheBudget() {
  // Reaching ready only says the handshake answered. Resetting the budget there let
  // a session that faults on its first poll reconnect forever without ever reaching
  // exhaustion: every reconnect verified again and wiped the count it had just spent.
  for (event, phase) in [
    (SessionEvent.verificationSucceeded, SessionState.Phase.ready),
    (.verificationRejected, .unverified),
  ] {
    let (next, _) = policy.reduce(state(.verifying, failureCount: 2), event)
    #expect(next.phase == phase)
    #expect(next.failureCount == 2, "\(event) restored the budget before the session proved itself")
  }
}

@Test func aSessionThatFaultsBeforeProvingStableExhaustsItsBudget() {
  // Drive the real cycle: every reconnect verifies, reaches ready, and faults on the
  // first poll — a declared read the device never answers. The loop must end.
  var current = state(.connecting)
  for _ in 0..<20 {
    (current, _) = policy.reduce(current, .channelOpened(current.attempt))
    #expect(current.phase == .verifying)
    (current, _) = policy.reduce(current, .verificationSucceeded)
    #expect(current.phase == .ready)
    (current, _) = policy.reduce(current, .sessionFault(.responseTimedOut))
    if current.phase == .retryExhausted { break }
    #expect(current.phase == .retryWaiting)
    (current, _) = policy.reduce(current, .backoffExpired)
  }
  #expect(current.phase == .retryExhausted, "a session that never settled reconnected forever")
  #expect(current.failureCount == policy.maximumFailureCount)
}

@Test func aSessionThatProvedStableStartsItsBudgetOverOnEveryDrop() {
  // The intent the reset exists for: a headset that drops its channel on every
  // wearing change, after working normally in between, never sticks at exhausted.
  var current = state(.connecting)
  for _ in 0..<20 {
    (current, _) = policy.reduce(current, .channelOpened(current.attempt))
    (current, _) = policy.reduce(current, .verificationSucceeded)
    (current, _) = policy.reduce(current, .sessionProvedStable)
    #expect(current.failureCount == 0)
    (current, _) = policy.reduce(current, .channelClosedUnexpectedly(current.attempt))
    #expect(current.phase == .retryWaiting, "normal wearing changes spent the budget")
    (current, _) = policy.reduce(current, .backoffExpired)
  }
}

@Test func provingStableOutsideALiveSessionChangesNothing() {
  // Only a live session can prove itself; a late signal must not restore the budget
  // of a reconnect that is still paying for a failure.
  for phase: SessionState.Phase in [.connecting, .verifying, .retryWaiting, .retryExhausted] {
    let start = state(phase, failureCount: 2)
    let (next, effects) = policy.reduce(start, .sessionProvedStable)
    #expect(next == start, "\(phase) took a stability signal")
    #expect(effects.isEmpty)
  }
}

@Test func exhaustedRetriesRearmOnASlowCadence() {
  // Exhaustion must not be forever while the device is still what is being listened
  // to: the channel churn of putting earbuds in can spend the whole budget in
  // seconds, and settle right after.
  let (next, exhaustEffects) = policy.reduce(
    state(.verifying, failureCount: 2),
    .verificationFailedTransient
  )
  #expect(next.phase == .retryExhausted)
  #expect(exhaustEffects.contains(.scheduleBackoff(attempt: 3)))

  let (rearmed, rearmEffects) = policy.reduce(
    state(.retryExhausted, failureCount: 3),
    .backoffExpired
  )
  #expect(rearmed.phase == .connecting)
  #expect(rearmed.failureCount == 3, "resetting the budget would turn every tick into a fresh burst")
  #expect(rearmEffects.contains { effect in
    if case .openChannel = effect { return true }
    return false
  })

  // A failed slow-cadence attempt goes straight back to exhausted with the next
  // tick armed — one try per tick, forever, rather than a consumed one-shot.
  let (failedAgain, failedEffects) = policy.reduce(rearmed, .channelFailed(rearmed.attempt))
  #expect(failedAgain.phase == .retryExhausted)
  #expect(failedEffects.contains { effect in
    if case .scheduleBackoff = effect { return true }
    return false
  })
}

@Test func aRefusedExhaustedTickRearmsInsteadOfConsumingTheBackoff() {
  // The backoff fired while the device was not the output. Consuming it here would
  // leave exhaustion with no way back except a manual retry or an output change to
  // a different device; instead the next tick is armed at the same slow cadence.
  let (still, effects) = policy.reduce(
    state(.retryExhausted, failureCount: 3, isDefaultOutput: false),
    .backoffExpired
  )
  #expect(still.phase == .retryExhausted)
  #expect(effects == [.scheduleBackoff(attempt: 3)])
}

@Test func losingTheOutputWhileExhaustedCancelsItsTimer() {
  let (next, effects) = policy.reduce(
    state(.retryExhausted, failureCount: 3),
    .defaultOutputChanged(nil)
  )
  #expect(next.phase == .released)
  #expect(effects.contains(.cancelBackoff), "the released phase inherited a live retry timer")
}

@Test func wakingIntoExhaustionRearmsTheSlowCadence() {
  // Sleep cancels the timer with the rest of the teardown, so the restore must arm
  // a new one: nothing else ever advances `retryExhausted`.
  let (asleep, sleepEffects) = policy.reduce(state(.retryExhausted, failureCount: 3), .willSleep)
  #expect(sleepEffects.contains(.cancelBackoff))

  let (awake, effects) = policy.reduce(asleep, .didWake(deviceA))
  #expect(awake.phase == .retryExhausted)
  #expect(effects == [.scheduleBackoff(attempt: 3)])
}

@Test func becomingTheDefaultOutputOpensAChannel() {
  let (next, effects) = policy.reduce(.released, .defaultOutputChanged(deviceA))
  #expect(next.phase == .connecting)
  #expect(next.target == deviceA)
  #expect(effects == [.openChannel(deviceA, next.attempt)])
}

@Test func verificationMustCompleteBeforeWritesAreAccepted() {
  #expect(!state(.connecting).acceptsWrites)
  #expect(!state(.verifying).acceptsWrites)
  #expect(!state(.recovering).acceptsWrites)
  #expect(state(.ready).acceptsWrites)
}

@Test func losingTheOutputWhileVerifyingDropsTheSession() {
  // Suspending here would let the grace period resume straight into `ready`,
  // skipping the verification that was still in flight.
  let (next, effects) = policy.reduce(state(.verifying), .defaultOutputChanged(nil))
  #expect(next.phase == .released)
  #expect(effects.contains(.invalidateSession))
}

@Test func losingTheOutputWhileReadySuspendsWithAGrace() {
  let (next, effects) = policy.reduce(state(.ready), .defaultOutputChanged(nil))
  #expect(next.phase == .suspended(resume: .ready))
  #expect(effects == [.startGrace])
}

@Test func returningWithinTheGraceResumesWithoutReconnecting() {
  let suspended = state(.suspended(resume: .ready))
  let (next, effects) = policy.reduce(suspended, .defaultOutputChanged(deviceA))
  #expect(next.phase == .ready)
  #expect(effects == [.cancelGrace])
}

@Test func aFaultWhileSuspendedReleasesRatherThanResumingOnABrokenStream() {
  // The grace holds the channel, and acknowledgements still go out on it. A fault
  // there — a stalled write above all — used to be ignored, so returning to the
  // device resumed onto a channel that could no longer carry anything, and the first
  // request after it waited out its whole timeout before anything was rebuilt.
  for fault: SessionFault in [.writeStalled, .responseTimedOut, .bufferOverflowed] {
    let (next, effects) = policy.reduce(state(.suspended(resume: .ready)), .sessionFault(fault))
    #expect(next.phase == .released, "\(fault) was ignored while suspended")
    #expect(effects.contains(.cancelGrace))
    #expect(effects.contains(.closeChannel))
    #expect(effects.contains(.failPendingRequests))
  }
}

@Test func disconnectingWhileSuspendedReleasesRatherThanResuming() {
  let suspended = state(.suspended(resume: .ready))
  let (closed, _) = policy.reduce(suspended, .channelClosedUnexpectedly(suspended.attempt))
  #expect(closed.phase == .released)

  // The channel is gone, so a later return to the output must not resume.
  let (next, _) = policy.reduce(closed, .defaultOutputChanged(deviceA))
  #expect(next.phase == .connecting)
}

// MARK: - Target switching

@Test func switchingToAnotherDeviceTearsDownTheOldSession() {
  let (next, effects) = policy.reduce(state(.ready), .defaultOutputChanged(deviceB))
  #expect(next.phase == .connecting)
  #expect(next.target == deviceB)
  #expect(effects.contains(.closeChannel))
  #expect(effects.contains(.invalidateSession))
  #expect({ if case .openChannel(let d, _) = effects.last { return d == deviceB } else { return false } }())
}

@Test func switchingAwayFromASuspendedDeviceCancelsItsGrace() {
  let suspended = state(.suspended(resume: .ready))
  let (next, effects) = policy.reduce(suspended, .defaultOutputChanged(deviceB))
  #expect(next.target == deviceB)
  #expect(effects.contains(.cancelGrace))
  #expect({ if case .openChannel(let d, _) = effects.last { return d == deviceB } else { return false } }())
}

@Test func returningToTheOriginalDeviceAfterANonCandidateReconnects() {
  var current = state(.ready)
  (current, _) = policy.reduce(current, .defaultOutputChanged(nil))
  #expect(current.phase == .suspended(resume: .ready))

  (current, _) = policy.reduce(current, .defaultOutputChanged(deviceA))
  #expect(current.phase == .ready)
  #expect(current.target == deviceA)
}

@Test func switchingToAnotherDeviceAfterANonCandidateTargetsTheNewDevice() {
  var current = state(.ready)
  (current, _) = policy.reduce(current, .defaultOutputChanged(nil))

  let (next, effects) = policy.reduce(current, .defaultOutputChanged(deviceB))
  #expect(next.target == deviceB)
  #expect(next.phase == .connecting)
  #expect(effects.contains { if case .openChannel(let d, _) = $0 { return d == deviceB } else { return false } })
}

@Test func anUnverifiedDeviceStaysConnectedAndUsable() {
  // Closing the channel because the model is unfamiliar would throw away every value
  // the device was willing to give, and every control it was willing to accept.
  //
  // The phase only says writes *may* be admitted here. Whether they actually are is
  // the coordinator's decision, made per device from the verification failure: an
  // unknown model or firmware the experimental gate recognises writes behind the
  // caveat, and a structural refusal stays read-only
  // (`SessionCoordinator.acceptsWrites`, `permitsUnverifiedWrites`).
  let (next, effects) = policy.reduce(state(.verifying), .verificationRejected)
  #expect(next.phase == .unverified)
  #expect(effects.isEmpty, "the session was torn down over an unfamiliar model")
  #expect(next.acceptsWrites)
  #expect(next.writesAreUnverified, "the caveat would not be shown")
}

@Test func anUnverifiedDeviceStillFollowsTheOutput() {
  let (suspended, _) = policy.reduce(state(.unverified), .defaultOutputChanged(nil))
  #expect(suspended.phase == .suspended(resume: .unverified))

  let (resumed, _) = policy.reduce(suspended, .defaultOutputChanged(deviceA))
  #expect(resumed.phase == .unverified, "resuming promoted an unverified device")
  #expect(resumed.writesAreUnverified, "the caveat was dropped by resuming")
}

@Test func switchingAwayFromAnUnverifiedDeviceConnectsTheNewOne() {
  let (next, effects) = policy.reduce(state(.unverified), .defaultOutputChanged(deviceB))
  #expect(next.phase == .connecting)
  #expect(next.target == deviceB)
  #expect(effects.contains { if case .openChannel(let d, _) = $0 { return d == deviceB } else { return false } })
}

// MARK: - Failures

@Test func automaticRetriesStopAtTheLimit() {
  // Drive the real cycle rather than rebuilding the state by hand. Reconstructing
  // it is what previously hid a reset of the budget on every backoff, which made
  // the limit unreachable and the reconnect loop endless.
  var current = state(.connecting)
  var backoffs = 0

  for _ in 0..<20 {
    let (afterFailure, failureEffects) = policy.reduce(current, .channelFailed(current.attempt))
    current = afterFailure

    if current.phase == .retryExhausted { break }

    #expect(current.phase == .retryWaiting)
    backoffs += 1
    #expect(failureEffects.contains(.scheduleBackoff(attempt: backoffs)))

    let (afterBackoff, _) = policy.reduce(current, .backoffExpired)
    current = afterBackoff
    #expect(current.phase == .connecting)
    #expect(current.failureCount == backoffs, "the retry budget was reset by the backoff")
  }

  #expect(current.phase == .retryExhausted)
  #expect(current.failureCount == 3)
}

@Test func successResetsTheFailureCount() {
  // Success is a session that proved itself, not one that merely verified.
  let (ready, _) = policy.reduce(state(.verifying, failureCount: 2), .verificationSucceeded)
  #expect(ready.phase == .ready)
  let (next, _) = policy.reduce(ready, .sessionProvedStable)
  #expect(next.phase == .ready)
  #expect(next.failureCount == 0)
}

@Test func manualRetryResetsTheFailureCount() {
  let (next, effects) = policy.reduce(state(.retryExhausted, failureCount: 3), .manualRetry)
  #expect(next.phase == .connecting)
  #expect(next.failureCount == 0)
  #expect(effects == [.openChannel(deviceA, next.attempt)])
}

@Test func losingTheOutputAbandonsAStalledRetry() {
  let (next, effects) = policy.reduce(state(.retryWaiting, failureCount: 1), .defaultOutputChanged(nil))
  #expect(next.phase == .released)
  #expect(effects == [.cancelBackoff])
}

// MARK: - Failures retrying cannot fix

@Test func aVerificationTheDeviceAnswersUnreadablyStopsRetrying() {
  // The device answered the handshake with something that does not parse. Asking
  // again gets the same answer, so it was a reconnect loop on the retry budget, then
  // the slow cadence forever — each pass holding the single control channel.
  let (incompatible, effects) = policy.reduce(
    state(.verifying, failureCount: 1),
    .verificationFailedPermanently
  )
  #expect(incompatible.phase == .incompatible)
  #expect(incompatible.target == deviceA, "the refusal must remember which device it is about")
  #expect(effects == [.closeChannel, .invalidateSession, .failPendingRequests])
  #expect(!incompatible.acceptsWrites)

  for event: SessionEvent in [.backoffExpired, .defaultOutputChanged(deviceA), .graceExpired] {
    let (still, stillEffects) = policy.reduce(incompatible, event)
    #expect(still.phase == .incompatible, "\(event) retried a failure that cannot change")
    #expect(stillEffects.isEmpty)
  }
}

@Test func anIncompatibleDeviceIsRetriedOnlyByHandOrByAnotherDevice() {
  let (retrying, effects) = policy.reduce(state(.incompatible), .manualRetry)
  #expect(retrying.phase == .connecting)
  #expect(effects == [.openChannel(deviceA, retrying.attempt)])

  let (refused, refusedEffects) = policy.reduce(
    state(.incompatible, isDefaultOutput: false), .manualRetry
  )
  #expect(refused.phase == .incompatible, "a retry connected to a device that is not the output")
  #expect(refusedEffects.isEmpty)

  let (other, otherEffects) = policy.reduce(state(.incompatible), .defaultOutputChanged(deviceB))
  #expect(other.phase == .connecting)
  #expect(other.target == deviceB)
  #expect(otherEffects == [.openChannel(deviceB, other.attempt)])

  let (released, releaseEffects) = policy.reduce(state(.incompatible), .defaultOutputChanged(nil))
  #expect(released.phase == .released)
  #expect(releaseEffects.isEmpty)
}

@Test func sleepDoesNotLaunderIncompatibility() {
  let (asleep, sleepEffects) = policy.reduce(state(.incompatible), .willSleep)
  #expect(asleep.phase == .sleeping(resume: .blocked(.incompatible)))
  #expect(sleepEffects.isEmpty, "the channel was already closed")

  let (awake, effects) = policy.reduce(asleep, .didWake(deviceA))
  #expect(awake.phase == .incompatible)
  #expect(effects.isEmpty)
}

// MARK: - Close completions

@Test func aCloseWeAskedForDoesNotUndoThePhaseThatRequestedIt() {
  for phase: SessionState.Phase in [.contended, .retryWaiting, .retryExhausted, .unverified] {
    let (next, effects) = policy.reduce(state(phase), .channelClosedByUs)
    #expect(next.phase == phase)
    #expect(effects.isEmpty)
  }
}

// MARK: - Recovery barrier

@Test func aSessionFaultTearsDownAndReconnectsOnBackoff() {
  // A mid-session fault cannot be recovered in place — what arrives afterwards can no
  // longer be attributed — so the session is torn down and reconnected on the retry
  // budget, rather than parking in a phase nothing advances (which left it down for
  // good).
  let (waiting, effects) = policy.reduce(state(.ready), .sessionFault(.responseTimedOut))
  #expect(waiting.phase == .retryWaiting)
  #expect(!waiting.acceptsWrites)
  #expect(effects.contains(.failPendingRequests))
  #expect(effects.contains(.closeChannel))
  #expect(effects.contains(where: { if case .scheduleBackoff = $0 { return true } else { return false } }))

  // When the backoff expires the channel is actually reopened.
  let (reconnecting, reconnectEffects) = policy.reduce(waiting, .backoffExpired)
  #expect(reconnecting.phase == .connecting)
  #expect(reconnectEffects.contains(where: { if case .openChannel = $0 { return true } else { return false } }))
}

@Test func aSessionFaultWhileUnverifiedIsNotSwallowed() {
  // `unverified` is the one pre-verification phase that admits writes, so a fault
  // there must invalidate and reconnect exactly like the verified phases. Dropping
  // it left the session running on a stream it could no longer attribute.
  for fault: SessionFault in [.responseTimedOut, .bufferOverflowed, .responseUnattributable] {
    let (next, effects) = policy.reduce(state(.unverified), .sessionFault(fault))
    #expect(next.phase == .retryWaiting, "\(fault) was ignored while unverified")
    #expect(!next.acceptsWrites)
    #expect(effects.contains(.closeChannel))
    #expect(effects.contains(.invalidateSession))
    #expect(effects.contains(.failPendingRequests))
    #expect(effects.contains(where: { if case .scheduleBackoff = $0 { return true } else { return false } }))
  }
}

// MARK: - Contention

@Test func anOutputNotificationDoesNotReconnectAContendedSession() {
  // Only the slow-cadence timer and the user move contention along; the same device
  // being announced as the output again is not news.
  let (contended, effects) = policy.reduce(
    state(.ready), .controlContended(ConnectionAttempt(0))
  )
  #expect(contended.phase == .contended)
  #expect(effects.contains(.scheduleContentionRetry))

  let (unchanged, outputEffects) = policy.reduce(contended, .defaultOutputChanged(deviceA))
  #expect(unchanged.phase == .contended)
  #expect(outputEffects.isEmpty)
}

@Test func contentionRetriesOnASlowCadence() {
  // An open timeout is read as contention, but nothing proves it: the async open has
  // been seen never calling back at all. Waiting for the user alone left a session
  // that was merely unlucky stuck until someone pressed retry, so contention tries
  // again on its own, slowly — each try can hang for the full open timeout.
  let (retrying, effects) = policy.reduce(state(.contended), .backoffExpired)
  #expect(retrying.phase == .connecting)
  #expect(retrying.failureCount == 0)
  #expect(effects.contains(.openChannel(deviceA, retrying.attempt)))

  // Timing out again goes straight back with the next tick armed.
  let (again, againEffects) = policy.reduce(retrying, .controlContended(retrying.attempt))
  #expect(again.phase == .contended)
  #expect(againEffects == [.cancelOpen, .scheduleContentionRetry])
}

@Test func aContentionTickWhileTheDeviceIsNotTheOutputRearms() {
  // Seizing the session for a device nobody is listening to would take control
  // away from the host that is; the tick waits for the next one instead.
  let (still, effects) = policy.reduce(
    state(.contended, isDefaultOutput: false),
    .backoffExpired
  )
  #expect(still.phase == .contended)
  #expect(effects == [.scheduleContentionRetry])
}

@Test func leavingContentionCancelsItsTimer() {
  let (released, releaseEffects) = policy.reduce(state(.contended), .defaultOutputChanged(nil))
  #expect(released.phase == .released)
  #expect(releaseEffects.contains(.cancelBackoff), "the released phase inherited a live retry timer")

  let (switched, switchEffects) = policy.reduce(state(.contended), .defaultOutputChanged(deviceB))
  #expect(switched.target == deviceB)
  #expect(switchEffects.contains(.cancelBackoff))
}

@Test func anOpenTimeoutAgainstAReachableOutputDeviceIsReadAsContention() {
  // The transport only reaches the open once the baseband connection is confirmed,
  // and this hardware answers a second control open by hanging while another host
  // holds the single control channel. So a timed-out open against the device the
  // user is listening to is contention, not retry budget: the retry path would hang
  // for the full timeout on every attempt without ever saying why.
  let connecting = state(.connecting, attempt: ConnectionAttempt(4))
  let (contended, effects) = policy.reduce(
    connecting, .controlContended(ConnectionAttempt(4))
  )
  #expect(contended.phase == .contended)
  #expect(effects == [.cancelOpen, .scheduleContentionRetry])

  // The reconnect button lives: a manual retry from here opens a fresh channel.
  let (retrying, retryEffects) = policy.reduce(contended, .manualRetry)
  #expect(retrying.phase == .connecting)
  #expect(retryEffects == [.openChannel(deviceA, retrying.attempt)])
}

@Test func aStaleOpenTimeoutCannotMarkALaterAttemptContended() {
  // The timed-out open belongs to an attempt the policy already abandoned; the live
  // attempt may be about to succeed and must not be branded contended for it.
  let connecting = state(.connecting, attempt: ConnectionAttempt(5))
  let (unchanged, effects) = policy.reduce(
    connecting, .controlContended(ConnectionAttempt(4))
  )
  #expect(unchanged.phase == .connecting)
  #expect(effects.isEmpty)
}

// MARK: - Sleep

@Test func sleepingRefusesToStartConnections() {
  let (asleep, effects) = policy.reduce(state(.ready), .willSleep)
  #expect(asleep.phase == .sleeping(resume: .reconnect))
  #expect(effects.contains(.closeChannel))

  let (still, noEffects) = policy.reduce(asleep, .defaultOutputChanged(deviceB))
  #expect(still.phase == .sleeping(resume: .reconnect))
  #expect(noEffects.isEmpty)
}

@Test func wakingReconnectsOnlyWhenACandidateIsTheOutput() {
  let asleep = state(.sleeping(resume: .reconnect))

  let (reconnect, effects) = policy.reduce(asleep, .didWake(deviceA))
  #expect(reconnect.phase == .connecting)
  #expect(effects == [.openChannel(deviceA, reconnect.attempt)])

  let (release, releaseEffects) = policy.reduce(asleep, .didWake(nil))
  #expect(release.phase == .released)
  #expect(releaseEffects.isEmpty)
}

// MARK: - Exhaustive sweep

// MARK: - Losing the output mid-recovery

@Test func aReconnectIsAbandonedWhenTheOutputIsGone() {
  let (waiting, _) = policy.reduce(state(.ready), .sessionFault(.responseTimedOut))
  #expect(waiting.phase == .retryWaiting)

  // If the device stops being the output before the backoff fires, the pending
  // reconnect is cancelled and no writable session is resurrected for a device the
  // user is no longer listening to.
  let (lost, effects) = policy.reduce(waiting, .defaultOutputChanged(nil))
  #expect(lost.phase == .released)
  #expect(effects.contains(.cancelBackoff))
  #expect(!lost.acceptsWrites)
}

// MARK: - Sleep must not launder refusals

@Test func sleepPreservesRefusalStates() {
  // Unverified is deliberately absent: it refuses writes, not connections, so its
  // wake path reconnects — covered by `wakingAnUnverifiedDeviceReconnects`.
  let cases: [(SessionState.Phase, String)] = [
    (.retryExhausted, "retryExhausted"),
    (.contended, "contended"),
  ]

  for (phase, label) in cases {
    let (asleep, _) = policy.reduce(state(phase), .willSleep)
    let (awake, effects) = policy.reduce(asleep, .didWake(deviceA))
    #expect(awake.phase == phase, "sleep laundered \(label)")
    #expect(
      !effects.contains { if case .openChannel = $0 { return true } else { return false } },
      "sleep let \(label) reconnect"
    )
    // Both refusals re-arm their slow-cadence timers on waking: sleep cancelled them
    // with the rest of the teardown, and nothing else ever advances either.
    if phase == .retryExhausted {
      #expect(
        effects.contains { if case .scheduleBackoff = $0 { return true } else { return false } }
      )
    } else {
      #expect(effects == [.scheduleContentionRetry])
    }
  }
}

@Test func sleepBlocksConnectionsEvenWithNothingConnected() {
  // Falling asleep from `released` must still latch the sleep guard, or an output
  // notification during sleep would open a channel.
  let (asleep, _) = policy.reduce(.released, .willSleep)
  #expect(asleep.phase == .sleeping(resume: .reconnect))

  let (still, effects) = policy.reduce(asleep, .defaultOutputChanged(deviceA))
  #expect(still.phase == .sleeping(resume: .reconnect))
  #expect(effects.isEmpty)

  let (awake, _) = policy.reduce(asleep, .didWake(deviceA))
  #expect(awake.phase == .connecting)
}

@Test func aBluetoothDisconnectDoesNotEndSleep() {
  let (asleep, _) = policy.reduce(state(.ready), .willSleep)

  let (still, _) = policy.reduce(asleep, .bluetoothDisconnected)
  #expect(still.phase == .sleeping(resume: .reconnect), "the disconnect cancelled sleep")

  // Waking must still be handled, rather than the state having fallen out of sleep.
  let (awake, _) = policy.reduce(still, .didWake(deviceA))
  #expect(awake.phase == .connecting)
}

@Test func aManualRetryAfterWakingWithoutAnOutputIsRefused() {
  // Waking restores the refusal, but the audio system has not yet said which device
  // is active. Retrying here would open a session for a device the user may not be
  // listening to, taking control from whichever host is.
  let (asleep, _) = policy.reduce(state(.contended, isDefaultOutput: true), .willSleep)
  let (awake, _) = policy.reduce(asleep, .didWake(nil))
  #expect(awake.phase == .contended)
  #expect(!awake.isTargetDefaultOutput)

  let (afterRetry, effects) = policy.reduce(awake, .manualRetry)
  #expect(afterRetry.phase == .contended, "a retry connected to a device that is not the output")
  #expect(effects.isEmpty)

  // Once the device is confirmed as the output, retrying is allowed again.
  let (confirmed, _) = policy.reduce(awake, .defaultOutputChanged(deviceA))
  let (reconnecting, openEffects) = policy.reduce(confirmed, .manualRetry)
  #expect(reconnecting.phase == .connecting)
  #expect(openEffects == [.openChannel(deviceA, reconnecting.attempt)])
}

@Test func wakingAnUnverifiedDeviceReconnects() {
  // Sleep tore the unverified device's channel down with everything else, so waking
  // must issue a fresh open exactly like the verified path. Restoring the bare
  // phase left a channel-less session the interface showed as operable, with
  // nothing ever reopening the channel. Verification re-runs on the reconnect, so
  // the write caveat is re-applied rather than laundered.
  let (asleep, _) = policy.reduce(state(.unverified), .willSleep)
  let (awake, effects) = policy.reduce(asleep, .didWake(deviceA))
  #expect(awake.phase == .connecting)
  #expect(effects == [.openChannel(deviceA, awake.attempt)])

  let (verifying, verifyEffects) = policy.reduce(awake, .channelOpened(awake.attempt))
  #expect(verifying.phase == .verifying)
  #expect(verifyEffects == [.startVerification])
}

@Test func wakingAnUnverifiedDeviceWithoutAnOutputWaitsForTheOutput() {
  // No output is known yet, so nothing may be opened — but the device must not be
  // parked in a channel-less unverified phase either, because no event ever
  // reopens a channel from there. Releasing lets the ordinary output notification
  // reconnect, the same way it does for a verified device.
  let (asleep, _) = policy.reduce(state(.unverified), .willSleep)
  let (awake, wakeEffects) = policy.reduce(asleep, .didWake(nil))
  #expect(awake.phase == .released)
  #expect(wakeEffects.isEmpty)

  let (reconnecting, effects) = policy.reduce(awake, .defaultOutputChanged(deviceA))
  #expect(reconnecting.phase == .connecting)
  #expect(effects == [.openChannel(deviceA, reconnecting.attempt)])
}

@Test func anOpenLandingAfterCancellationIsClosed() {
  let (connecting, open) = policy.reduce(.released, .defaultOutputChanged(deviceA))
  guard case .openChannel(_, let attempt) = open[0] else {
    Issue.record("expected an open effect")
    return
  }

  // Sleep cancels the attempt but keeps its identifier.
  let (asleep, _) = policy.reduce(connecting, .willSleep)
  let (still, effects) = policy.reduce(asleep, .channelOpened(attempt))

  #expect(still.phase == .sleeping(resume: .reconnect))
  #expect(effects == [.closeChannel], "a channel opened after cancellation was leaked")
}

@Test func sleepStillAllowsADifferentDeviceAfterARefusal() {
  let (asleep, _) = policy.reduce(state(.contended), .willSleep)
  let (awake, effects) = policy.reduce(asleep, .didWake(deviceB))
  #expect(awake.phase == .connecting)
  #expect(awake.target == deviceB)
  #expect(effects == [.openChannel(deviceB, awake.attempt)])
}

// MARK: - Stale completions

@Test func aCompletionFromAnAbandonedAttemptIsRejected() {
  let (connectingToA, openA) = policy.reduce(.released, .defaultOutputChanged(deviceA))
  guard case .openChannel(_, let attemptA) = openA[0] else {
    Issue.record("expected an open effect")
    return
  }

  let (connectingToB, openB) = policy.reduce(connectingToA, .defaultOutputChanged(deviceB))
  guard case .openChannel(_, let attemptB) = openB.last else {
    Issue.record("expected an open effect for the new device")
    return
  }
  #expect(attemptA != attemptB)

  // A's channel finally opens, long after we moved to B.
  let (unchanged, effects) = policy.reduce(connectingToB, .channelOpened(attemptA))
  #expect(unchanged.phase == .connecting)
  #expect(unchanged.target == deviceB)
  #expect(effects == [.closeChannel], "a stale channel must be closed, not merely ignored")

  let (verifying, _) = policy.reduce(connectingToB, .channelOpened(attemptB))
  #expect(verifying.phase == .verifying)
}

@Test func releasingKeepsTheAttemptCounter() {
  // `released` used to be a fresh state, attempt and all, so the next connection
  // reused the number of an attempt abandoned moments earlier — and that attempt's
  // late completion (the cancelled open failing, or landing after all) passed for
  // the live one.
  let releases: [[SessionEvent]] = [
    [.defaultOutputChanged(nil)],
    [.manualRelease],
    [.bluetoothDisconnected],
    [.willSleep, .didWake(nil)],
  ]
  for release in releases {
    let (connecting, _) = policy.reduce(.released, .defaultOutputChanged(deviceA))
    let abandoned = connecting.attempt
    var released = connecting
    for event in release {
      (released, _) = policy.reduce(released, event)
    }
    #expect(released.phase == .released)

    let (reconnecting, _) = policy.reduce(released, .defaultOutputChanged(deviceB))
    #expect(reconnecting.attempt != abandoned, "\(release) reused an abandoned attempt")

    let (afterFailure, failureEffects) = policy.reduce(reconnecting, .channelFailed(abandoned))
    #expect(afterFailure == reconnecting, "a cancelled open failing late failed the live one")
    #expect(failureEffects.isEmpty)
    let (afterOpen, openEffects) = policy.reduce(reconnecting, .channelOpened(abandoned))
    #expect(afterOpen == reconnecting, "the other device's late channel was adopted")
    #expect(openEffects == [.closeChannel])
  }
}

@Test func aStaleOpenWhileTheLiveOneVerifiesOnlyClosesIt() {
  // The phase does not move for a stale completion, and here it is already
  // `verifying`: the coordinator adopts a channel only when told to verify it, so
  // the effects alone must say whose channel this is.
  let verifying = state(.verifying, attempt: ConnectionAttempt(5))
  let (next, effects) = policy.reduce(verifying, .channelOpened(ConnectionAttempt(4)))
  #expect(next == verifying)
  #expect(effects == [.closeChannel])
}

// MARK: - Construction

@Test func aNonReleasedPhaseWithoutATargetIsNotRepresentable() {
  let invalid = SessionState(phase: .ready, target: nil)
  #expect(invalid.phase == .released)
  #expect(!invalid.acceptsWrites)
}

@Test func failureCountsCannotGoNegativeOrOverflow() {
  #expect(SessionState(phase: .ready, target: deviceA, failureCount: -5).failureCount == 0)

  let saturated = state(.ready, failureCount: Int.max)
  let (next, _) = policy.reduce(saturated, .channelClosedUnexpectedly(saturated.attempt))
  #expect(next.failureCount == Int.max)
  #expect(next.phase == .retryExhausted)
}

// MARK: - Table-driven transitions

@Test func transitionsMatchTheSpecifiedTable() {
  let attempt = ConnectionAttempt(7)
  let cases: [(SessionState, SessionEvent, SessionState.Phase)] = [
    (state(.released, target: nil), .defaultOutputChanged(deviceA), .connecting),
    (state(.released, target: nil), .defaultOutputChanged(nil), .released),
    (state(.connecting, attempt: attempt), .channelOpened(attempt), .verifying),
    (state(.connecting, attempt: attempt), .channelFailed(attempt), .retryWaiting),
    (state(.connecting, attempt: attempt), .controlContended(attempt), .contended),
    (state(.connecting), .defaultOutputChanged(nil), .released),
    (state(.verifying), .verificationSucceeded, .ready),
    (state(.verifying), .verificationRejected, .unverified),
    (state(.verifying), .verificationFailedTransient, .retryWaiting),
    (state(.verifying), .verificationFailedPermanently, .incompatible),
    (state(.incompatible), .manualRetry, .connecting),
    (state(.incompatible), .defaultOutputChanged(nil), .released),
    (state(.verifying), .defaultOutputChanged(nil), .released),
    (state(.verifying), .controlContended(ConnectionAttempt(0)), .contended),
    (state(.ready), .defaultOutputChanged(nil), .suspended(resume: .ready)),
    (state(.ready), .controlContended(ConnectionAttempt(0)), .contended),
    (state(.ready), .sessionFault(.responseTimedOut), .retryWaiting),
    (state(.ready), .bluetoothDisconnected, .released),
    (state(.suspended(resume: .ready)), .defaultOutputChanged(deviceA), .ready),
    (state(.suspended(resume: .ready)), .graceExpired, .released),
    (
      state(.suspended(resume: .ready), attempt: attempt),
      .channelClosedUnexpectedly(attempt), .released
    ),
    (state(.retryWaiting), .backoffExpired, .connecting),
    (state(.retryWaiting), .defaultOutputChanged(nil), .released),
    (state(.retryExhausted), .manualRetry, .connecting),
    (state(.retryExhausted), .defaultOutputChanged(nil), .released),
    (state(.contended), .manualRetry, .connecting),
    (state(.contended), .defaultOutputChanged(deviceA), .contended),
    (state(.contended), .defaultOutputChanged(nil), .released),
    (state(.unverified), .defaultOutputChanged(deviceA), .unverified),
    (state(.unverified), .defaultOutputChanged(nil), .suspended(resume: .unverified)),
    (state(.unverified), .sessionFault(.responseTimedOut), .retryWaiting),
    // `recovering` is unreachable, but a constructed state must still be able to
    // leave it; the exits are kept while the entries are gone.
    (state(.recovering), .defaultOutputChanged(nil), .released),
    (state(.recovering), .sessionFault(.bufferOverflowed), .retryWaiting),
  ]

  for (start, event, expected) in cases {
    let (next, _) = policy.reduce(start, event)
    #expect(next.phase == expected, "\(start.phase) + \(event) gave \(next.phase)")
  }
}

@Test func invariantsHoldForEveryStateAndEventPair() {
  let attempt = ConnectionAttempt(3)
  let phases: [SessionState.Phase] = [
    .released, .connecting, .verifying, .ready, .contended,
    .suspended(resume: .ready), .retryWaiting, .retryExhausted,
    .unverified, .sleeping(resume: .reconnect), .sleeping(resume: .blocked(.unverified)),
    .recovering, .incompatible, .sleeping(resume: .blocked(.incompatible)),
  ]
  let events: [SessionEvent] = [
    .defaultOutputChanged(deviceA), .defaultOutputChanged(deviceB), .defaultOutputChanged(nil),
    .channelOpened(attempt), .channelFailed(attempt), .channelClosedUnexpectedly(attempt),
    .channelClosedByUs, .verificationSucceeded, .verificationRejected,
    .verificationFailedTransient, .verificationFailedPermanently,
    .controlContended(attempt), .sessionFault(.bufferOverflowed),
    .graceExpired, .backoffExpired, .bluetoothDisconnected,
    .willSleep, .didWake(deviceA), .didWake(nil), .manualRetry, .manualRelease,
    .sessionProvedStable,
  ]

  for phase in phases {
    for event in events {
      let (next, _) = policy.reduce(state(phase, attempt: attempt), event)

      if next.phase != .ready && next.phase != .unverified {
        #expect(!next.acceptsWrites)
      }

      // `released` has nothing to track, and sleep can begin before anything has
      // ever connected. Every other phase must remember which device it concerns.
      let mayOmitTarget: Bool
      switch next.phase {
      case .released, .sleeping: mayOmitTarget = true
      default: mayOmitTarget = false
      }
      if !mayOmitTarget {
        #expect(next.target != nil, "\(phase) + \(event) lost its target")
      }
      #expect(next.failureCount >= 0)
      // A request left in flight on an invalidated session holds the wire until its
      // timeout, and that timeout then faults whatever session exists by then.
      let (_, effects) = policy.reduce(state(phase, attempt: attempt), event)
      if effects.contains(.invalidateSession) {
        #expect(
          effects.contains(.failPendingRequests),
          "\(phase) + \(event) invalidated the session but left its requests pending"
        )
      }
      // Attempt numbers only ever move forward. Releasing must not rewind them, or
      // an abandoned attempt's completion matches the next one.
      if next.phase == .released {
        #expect(next.attempt == attempt, "\(phase) + \(event) rewound the attempt")
      }
      // Writes may only reopen from a phase that had a verified session.
      if next.acceptsWrites {
        // Waking restores whatever the session was before sleeping, so a usable
        // session may legitimately come back from sleep.
        let allowed: [SessionState.Phase] = [
          .ready, .unverified, .verifying, .recovering,
          .suspended(resume: .ready), .suspended(resume: .unverified),
          .sleeping(resume: .blocked(.unverified)),
        ]
        #expect(allowed.contains(phase), "\(phase) + \(event) opened writes")
      }
    }
  }
}
