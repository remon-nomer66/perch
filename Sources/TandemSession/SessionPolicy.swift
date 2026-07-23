import Foundation

/// Stable identity of a controllable device.
///
/// The raw value is a Bluetooth address. It never reaches the interface or the log;
/// anything persisted stores a hash instead.
public struct DeviceIdentity: Hashable, Sendable {
  public let rawValue: String

  /// Normalised on the way in. Core Audio writes addresses with dashes, IOBluetooth
  /// reports them lowercase, and system profiler uses uppercase colons; comparing the
  /// raw strings silently fails to find a device that is plainly there.
  public init(_ value: String) {
    rawValue = value.replacingOccurrences(of: "-", with: ":").uppercased()
  }
}

public enum SessionFault: Equatable, Sendable {
  case responseTimedOut
  case bufferOverflowed
  case responseUnattributable
}

public enum SessionEvent: Equatable, Sendable {
  /// The default audio output became this device, or `nil` when it became anything
  /// that cannot be controlled. Mapping non-candidates to `nil` keeps the reducer
  /// free of device eligibility rules.
  case defaultOutputChanged(DeviceIdentity?)
  case channelOpened(ConnectionAttempt)
  case channelFailed(ConnectionAttempt)
  case channelClosedUnexpectedly(ConnectionAttempt)
  case channelClosedByUs
  case verificationSucceeded
  case verificationRejected
  case verificationFailedTransient
  /// Another host most likely holds the device's single control channel. Fired when
  /// an open times out against a device that is provably reachable — the transport
  /// verified the baseband connection before opening, and this hardware answers a
  /// second control open by hanging rather than refusing, so a hang against a
  /// reachable device is the most honest contention signal there is. The attempt is
  /// carried so a timeout from an abandoned open cannot mark a later session.
  case controlContended(ConnectionAttempt)
  case sessionFault(SessionFault)
  case graceExpired
  case backoffExpired
  case bluetoothDisconnected
  case willSleep
  case didWake(DeviceIdentity?)
  case manualRetry
  case manualRelease
}

/// Side effects are described, not performed. `SessionCoordinator` executes them,
/// which keeps this reducer pure and exhaustively testable.
public enum SessionEffect: Equatable, Sendable {
  case openChannel(DeviceIdentity, ConnectionAttempt)
  case cancelOpen
  case closeChannel
  case invalidateSession
  case failPendingRequests
  case startVerification
  case startGrace
  case cancelGrace
  case scheduleBackoff(attempt: Int)
  case cancelBackoff
}

public struct SessionState: Equatable, Sendable {
  /// Why a sleeping session must not simply reconnect on wake.
  ///
  /// Sleep would otherwise launder every refusal: an incompatible device, an
  /// exhausted retry budget, and a session another host holds would all come back
  /// as a fresh connection attempt.
  public enum SleepResume: Equatable, Sendable {
    case reconnect
    case blocked(Blocked)

    public enum Blocked: Equatable, Sendable {
      case unverified
      case retryExhausted
      case contended
    }
  }

  public enum Phase: Equatable, Sendable {
    case released
    case connecting
    case verifying
    case ready
    case contended
    /// The device stopped being the default output. The channel is held for a grace
    /// period so a brief switch away does not cost a reconnect, but nothing may talk
    /// on it: the coordinator pauses the readings poll and refuses writes with a
    /// typed error until the device is the output again.
    case suspended(resume: Resume)
    case retryWaiting
    /// Transient failures reached the limit. Recoverable by hand.
    case retryExhausted
    /// Connected and usable, but this model has never been verified against the
    /// encodings this application sends.
    ///
    /// Writing is permitted because the operator asked for it knowingly. What remains
    /// is the read-back check: a value that does not come back as requested is
    /// reported rather than assumed to have worked. That detects a wrong write; it
    /// cannot prevent one.
    case unverified
    case sleeping(resume: SleepResume)
    /// Unreachable. A mid-session fault now tears the session down and reconnects
    /// on the retry budget, and the reconnect re-verifies and re-reads everything,
    /// which is the barrier this phase used to provide. No transition enters it any
    /// more; the case remains only because the interface layer matches on the phase
    /// and removing a public case would break it at the source level. Transitions
    /// *out* of it are kept so a state constructed with it can still leave.
    case recovering

    public enum Resume: Equatable, Sendable {
      case ready
      case unverified
    }
  }

  public private(set) var phase: Phase
  public private(set) var target: DeviceIdentity?
  public private(set) var failureCount: Int
  public private(set) var attempt: ConnectionAttempt
  /// Whether the target is the audio output right now.
  ///
  /// Tracked rather than inferred from the phase: waking can restore a refusal
  /// before the audio system has said which device is active, and a manual retry
  /// must not seize a session for a device the user is not listening to.
  public private(set) var isTargetDefaultOutput: Bool

  public init(
    phase: Phase = .released,
    target: DeviceIdentity? = nil,
    failureCount: Int = 0,
    attempt: ConnectionAttempt = ConnectionAttempt(0),
    isTargetDefaultOutput: Bool = false
  ) {
    // Every phase except these two needs a target to tell "this device" from "some
    // other device" when the next event arrives. Sleeping is exempt because the
    // machine can fall asleep having never connected to anything, and it still has
    // to block connections until it wakes.
    let mayOmitTarget: Bool
    switch phase {
    case .released: mayOmitTarget = true
    case .sleeping: mayOmitTarget = true
    default: mayOmitTarget = false
    }

    if target == nil && !mayOmitTarget {
      self.phase = .released
      self.target = nil
    } else {
      self.phase = phase
      self.target = phase == .released ? nil : target
    }
    self.failureCount = max(0, failureCount)
    self.attempt = attempt
    self.isTargetDefaultOutput = self.target == nil ? false : isTargetDefaultOutput
  }

  public static let released = SessionState()

  /// `suspended` is deliberately excluded even though the channel is still open:
  /// the device is no longer what the user is listening to, so a write there must
  /// be refused with a typed error rather than sent into the grace period.
  public var acceptsWrites: Bool { phase == .ready || phase == .unverified }

  /// True when the encodings being sent have never been checked against this model.
  public var writesAreUnverified: Bool { phase == .unverified }
}

public struct SessionPolicy: Sendable {
  public let maximumFailureCount: Int

  public init(maximumFailureCount: Int = 5) {
    precondition(maximumFailureCount > 0, "a session must be allowed at least one attempt")
    self.maximumFailureCount = maximumFailureCount
  }

  public func reduce(
    _ state: SessionState,
    _ event: SessionEvent
  ) -> (SessionState, [SessionEffect]) {
    // Ordered rules. The first match wins; later rules never see the event.
    if let outcome = reduceStaleCompletion(state, event) { return outcome }

    switch event {
    case .willSleep:
      if case .sleeping = state.phase { return (state, []) }
      return (
        state.moved(to: .sleeping(resume: sleepResume(for: state.phase))),
        teardown(from: state)
      )
    case .manualRelease:
      guard state.phase != .released else { return (state, []) }
      return (.released, teardown(from: state))
    default:
      break
    }

    // Sleep outranks everything below, including a Bluetooth disconnect. Falling out
    // of `sleeping` early would drop the wake handling and let an output change open
    // a channel while the machine is still asleep.
    if let outcome = reduceSleeping(state, event) { return outcome }

    if case .bluetoothDisconnected = event {
      guard state.target != nil else { return (state, []) }
      return (.released, teardown(from: state))
    }

    if let outcome = reduceTargetChange(state, event) { return outcome }

    // Whether the target is the output is independent of the phase, so record it
    // before the phase rules run. A phase that stays put still has to learn that the
    // device came back, or a later manual retry would be refused forever.
    var working = state
    if case .defaultOutputChanged(let device) = event {
      working = state.withDefaultOutput(device != nil && device == state.target)
    }

    return reducePhase(working, event)
  }

  // MARK: - Ordered rules

  /// Rejects channel completions that no longer belong to the live attempt.
  private func reduceStaleCompletion(
    _ state: SessionState,
    _ event: SessionEvent
  ) -> (SessionState, [SessionEffect])? {
    switch event {
    case .channelOpened(let attempt):
      // Matching the attempt is not enough. Cancelling moves the phase on while
      // keeping the attempt, so an open that lands afterwards must still be closed
      // rather than left to leak.
      if attempt == state.attempt, state.phase == .connecting { return nil }
      return (state, [.closeChannel])

    case .channelFailed(let attempt), .channelClosedUnexpectedly(let attempt),
      .controlContended(let attempt):
      // Contention is attempt-guarded like the failures: an abandoned open that
      // times out later must not mark a session it never belonged to as contended.
      return attempt == state.attempt ? nil : (state, [])

    default:
      return nil
    }
  }

  private func sleepResume(for phase: SessionState.Phase) -> SessionState.SleepResume {
    switch phase {
    case .unverified: .blocked(.unverified)
    case .retryExhausted: .blocked(.retryExhausted)
    case .contended: .blocked(.contended)
    default: .reconnect
    }
  }

  private func reduceSleeping(
    _ state: SessionState,
    _ event: SessionEvent
  ) -> (SessionState, [SessionEffect])? {
    guard case .sleeping(let resume) = state.phase else { return nil }
    guard case .didWake(let device) = event else {
      // Nothing may start a connection while asleep.
      return (state, [])
    }

    // A refusal survives the sleep. Restoring it even when no candidate is the
    // output yet keeps a later notification for the same device from laundering it
    // into a fresh connection.
    if case .blocked(let blocked) = resume, device == nil || device == state.target {
      // Unverified is a write refusal, not a connection refusal: before sleeping it
      // held an open channel with reads flowing, so waking must reconnect the way a
      // verified device does. Restoring the bare phase left a channel-less session
      // the interface showed as operable, with nothing ever issuing the open.
      // Verification re-runs on the reconnect and re-applies the caveat, so the
      // refusal is not laundered. Without an output the device may no longer be
      // what is being listened to, so release and let the output notification
      // reconnect — the same path a verified device takes.
      if blocked == .unverified {
        guard let device else { return (.released, []) }
        return start(connectingTo: device, from: state)
      }
      let restored: SessionState.Phase =
        switch blocked {
        case .unverified: .unverified
        case .retryExhausted: .retryExhausted
        case .contended: .contended
        }
      // The output is unknown until the audio system reports one, so the refusal
      // comes back without permission to reconnect. Exhaustion alone re-arms its
      // slow-cadence timer, because nothing else ever advances it.
      let effects: [SessionEffect] =
        blocked == .retryExhausted
        ? [.scheduleBackoff(attempt: max(state.failureCount, 1))]
        : []
      return (state.moved(to: restored, isTargetDefaultOutput: device != nil), effects)
    }

    guard let device else { return (.released, []) }
    return start(connectingTo: device, from: state)
  }

  private func reduceTargetChange(
    _ state: SessionState,
    _ event: SessionEvent
  ) -> (SessionState, [SessionEffect])? {
    guard case .defaultOutputChanged(let device) = event,
      let device,
      let current = state.target,
      device != current
    else {
      return nil
    }
    // Switching devices must tear down everything the old target owned, including
    // timers, or they will interfere with the new connection.
    let (next, open) = start(connectingTo: device, from: state)
    return (next, teardown(from: state) + open)
  }

  // MARK: - Per-phase rules

  private func reducePhase(
    _ state: SessionState,
    _ event: SessionEvent
  ) -> (SessionState, [SessionEffect]) {
    switch (state.phase, event) {
    case (.released, .defaultOutputChanged(let device)):
      guard let device else { return (state, []) }
      return start(connectingTo: device, from: state)

    case (.connecting, .channelOpened):
      return (state.moved(to: .verifying), [.startVerification])

    case (.connecting, .channelFailed):
      return failed(state)

    case (.connecting, .defaultOutputChanged(nil)):
      return (.released, [.cancelOpen, .closeChannel])

    case (.verifying, .verificationSucceeded):
      return (state.moved(to: .ready, failureCount: 0), [])

    // The channel stays open. Only writing is refused. Connecting to an unverified
    // device is still a successful connection, so the failure budget starts over: a
    // headset that drops the channel on every wearing change would otherwise spend
    // the whole budget across hours of normal use and stick at exhausted.
    case (.verifying, .verificationRejected):
      return (state.moved(to: .unverified, failureCount: 0), [])

    case (.verifying, .verificationFailedTransient):
      return failed(state)

    // An unfinished session must not survive into `suspended`: resuming from there
    // would reach `ready` without completing verification or recovery.
    case (.verifying, .defaultOutputChanged(nil)), (.recovering, .defaultOutputChanged(nil)):
      return (.released, [.closeChannel, .invalidateSession, .failPendingRequests])

    case (.ready, .defaultOutputChanged(nil)):
      return (
        state.moved(to: .suspended(resume: .ready), isTargetDefaultOutput: false),
        [.startGrace]
      )

    case (.unverified, .defaultOutputChanged(nil)):
      return (
        state.moved(to: .suspended(resume: .unverified), isTargetDefaultOutput: false),
        [.startGrace]
      )

    case (.suspended, .defaultOutputChanged(let device)):
      guard device != nil, case .suspended(let resume) = state.phase else { return (state, []) }
      switch resume {
      case .ready:
        return (state.moved(to: .ready, isTargetDefaultOutput: true), [.cancelGrace])
      case .unverified:
        return (state.moved(to: .unverified, isTargetDefaultOutput: true), [.cancelGrace])
      }

    case (.suspended, .graceExpired):
      return (.released, [.cancelGrace, .closeChannel, .invalidateSession])

    case (.suspended, .channelClosedUnexpectedly):
      return (.released, [.cancelGrace, .invalidateSession, .failPendingRequests])

    case (.connecting, .controlContended):
      // The open hung until its timeout against a device the transport had already
      // confirmed as connected, while it was still the default output. On this
      // hardware a second control open hangs while another host holds the single
      // control channel (docs/rfcomm-transport-notes.md §7), so that combination is
      // read as contention rather than burned as retry budget: the retry path would
      // hang for the full timeout on every attempt, while `contended` says what is
      // actually happening and waits for the user or for the output to move.
      // A connecting state whose device stopped being the output has released
      // already, so the guard is only for states constructed by hand.
      guard state.isTargetDefaultOutput else { return failed(state) }
      return (state.moved(to: .contended), [.cancelOpen])

    case (.ready, .controlContended), (.verifying, .controlContended),
      (.recovering, .controlContended), (.unverified, .controlContended):
      return (state.moved(to: .contended), [.closeChannel, .invalidateSession])

    case (.ready, .channelClosedUnexpectedly), (.verifying, .channelClosedUnexpectedly),
      (.recovering, .channelClosedUnexpectedly), (.unverified, .channelClosedUnexpectedly):
      return failed(state)

    case (.ready, .sessionFault), (.verifying, .sessionFault), (.recovering, .sessionFault),
      (.unverified, .sessionFault):
      // A fault mid-session means we can no longer attribute what arrives, so the
      // connection is torn down and rebuilt. Route it through the connection-failure
      // path so the reconnect runs on the same backoff budget, rather than parking in
      // a recovery phase that nothing advances (which left the session down for good).
      // `unverified` is included because it is a live, writable session like the
      // others; swallowing its faults left it running on a stream it could no longer
      // attribute.
      return failed(state)

    case (.retryWaiting, .backoffExpired):
      guard let target = state.target else { return (.released, [.cancelBackoff]) }
      let (next, open) = start(
        connectingTo: target,
        from: state,
        failureCount: state.failureCount
      )
      return (next, [.cancelBackoff] + open)

    case (.retryWaiting, .defaultOutputChanged(nil)):
      return (.released, [.cancelBackoff])

    case (.contended, .defaultOutputChanged(nil)), (.retryExhausted, .defaultOutputChanged(nil)):
      return (.released, teardown(from: state))

    case (.contended, .manualRetry), (.retryExhausted, .manualRetry):
      // Seizing the session for a device the user is not listening to would take
      // control away from whichever host actually is.
      guard let target = state.target, state.isTargetDefaultOutput else { return (state, []) }
      return start(connectingTo: target, from: state)

    case (.retryExhausted, .backoffExpired):
      // The slow cadence must survive its own ticks: consuming the backoff while
      // the device is not the output would make exhaustion permanent, with nothing
      // left to advance it. The spent budget is carried so a failed attempt goes
      // straight back to exhausted — one try per tick, not a fresh burst — and the
      // executor caps the delay curve, so the cadence stays a constant low rate.
      guard let target = state.target, state.isTargetDefaultOutput else {
        return (state, [.scheduleBackoff(attempt: max(state.failureCount, 1))])
      }
      return start(connectingTo: target, from: state, failureCount: state.failureCount)

    // A close we asked for is already reflected in the phase that requested it.
    // Treating the completion as another transition would knock `contended` and
    // `retryWaiting` back to `released`.
    case (_, .channelClosedByUs):
      return (state, [])

    default:
      return (state, [])
    }
  }

  // MARK: - Helpers

  /// `failureCount` is carried explicitly because a retry after a backoff has to
  /// keep the budget it has already spent. Resetting it there would make the retry
  /// limit unreachable and reconnect forever.
  private func start(
    connectingTo device: DeviceIdentity,
    from state: SessionState,
    failureCount: Int = 0
  ) -> (SessionState, [SessionEffect]) {
    let attempt = state.attempt.next
    return (
      SessionState(
        phase: .connecting,
        target: device,
        failureCount: failureCount,
        attempt: attempt,
        isTargetDefaultOutput: true
      ),
      [.openChannel(device, attempt)]
    )
  }

  private func failed(_ state: SessionState) -> (SessionState, [SessionEffect]) {
    let count = state.failureCount == Int.max ? Int.max : state.failureCount + 1
    let shared: [SessionEffect] = [.closeChannel, .invalidateSession, .failPendingRequests]
    guard count < maximumFailureCount else {
      // Exhaustion is a pause, not a verdict: a slow-cadence backoff keeps trying,
      // because the burst that spent the budget — earbuds being put in, a device
      // rebooting — usually settles moments later.
      return (
        state.moved(to: .retryExhausted, failureCount: count),
        shared + [.scheduleBackoff(attempt: count)]
      )
    }
    return (
      state.moved(to: .retryWaiting, failureCount: count),
      shared + [.scheduleBackoff(attempt: count)]
    )
  }

  /// Releases whatever the phase currently owns, and nothing else.
  private func teardown(from state: SessionState) -> [SessionEffect] {
    switch state.phase {
    case .released, .sleeping, .contended:
      return []
    case .retryExhausted:
      // Exhaustion owns its slow-cadence retry timer.
      return [.cancelBackoff]
    case .connecting:
      return [.cancelOpen, .closeChannel]
    case .verifying, .ready, .recovering, .unverified:
      return [.closeChannel, .invalidateSession, .failPendingRequests]
    case .suspended:
      return [.cancelGrace, .closeChannel, .invalidateSession, .failPendingRequests]
    case .retryWaiting:
      return [.cancelBackoff]
    }
  }
}

extension SessionState {
  fileprivate func withDefaultOutput(_ isDefaultOutput: Bool) -> SessionState {
    SessionState(
      phase: phase,
      target: target,
      failureCount: failureCount,
      attempt: attempt,
      isTargetDefaultOutput: isDefaultOutput
    )
  }

  fileprivate func moved(
    to phase: Phase,
    failureCount: Int? = nil,
    isTargetDefaultOutput: Bool? = nil
  ) -> SessionState {
    SessionState(
      phase: phase,
      target: target,
      failureCount: failureCount ?? self.failureCount,
      attempt: attempt,
      isTargetDefaultOutput: isTargetDefaultOutput ?? self.isTargetDefaultOutput
    )
  }
}
