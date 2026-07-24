import Foundation
import TandemCore

/// Establishes that a connected device is one this application may write to.
///
/// Separated behind a protocol because verification is a conversation with the
/// device, and the coordinator has to be exercisable without one.
public protocol DeviceVerifying: Sendable {
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome
}

/// The result of reading a device and comparing it with the verified profiles.
///
/// A device we cannot control is still worth describing. Discarding the fingerprint on
/// rejection would leave the interface unable to say which device it is refusing, or
/// to help the user ask for it to be supported.
public enum VerificationOutcome: Equatable, Sendable {
  case verified(TandemVerifiedDeviceProfile, TandemDeviceFingerprint)
  case unsupported(TandemDeviceFingerprint, reason: TandemDeviceVerificationFailure)

  public var fingerprint: TandemDeviceFingerprint {
    switch self {
    case .verified(_, let fingerprint), .unsupported(let fingerprint, _): fingerprint
    }
  }
}

/// What a verification or a feature needs from the session: send a frame, get one
/// back.
///
/// The frame is supplied by a builder rather than finished, because the alternating
/// sequence number belongs to the session, not to the caller.
public protocol SessionRequesting: Sendable {
  func request(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame

  /// Like `request`, but a no-answer is expected. On timeout it fails only this call
  /// and leaves the session running, where `request` rebuilds the session. Used by the
  /// diagnostic sweep, which asks about functions the device may not implement: one
  /// unanswered probe must not tear down a working connection. Defaults to `request`
  /// for conformers that do not distinguish the two.
  func probe(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame
}

extension SessionRequesting {
  public func probe(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    try await request(build, matching: matching)
  }
}

public enum SessionRequestFailure: Error, Equatable, Sendable {
  case notReady
  case failed(RequestFailure)
  case channel(ChannelFailure)
}

/// The single place that owns session identity, runs the policy's effects, and moves
/// bytes between the channel and the rest of the session.
///
/// Numbering and effect execution live together deliberately. Split across two
/// actors, an invalidation could land after a request had already been admitted
/// against the state it invalidated.
public actor SessionCoordinator {
  public struct Timeouts: Sendable {
    public var response: Duration
    public var grace: Duration
    public var backoffUnit: Duration
    /// Overrides the dialect-derived readings poll interval. Internal and test-only:
    /// production always derives the cadence from the dialect, so nothing here can
    /// bake in a model-specific value.
    var readingIntervalOverride: Duration?

    // An acknowledgement timeout used to live here, but nothing ever armed it: the
    // response timeout is the one deadline a request needs, and a reply arriving
    // without its acknowledgement is recorded on the request rather than timed.
    public init(
      response: Duration = .seconds(5),
      grace: Duration = .seconds(60),
      // Half a second before the first retry: a headset that drops its channel on a
      // wearing change is back about a second later, which should feel immediate.
      // Doubling still spaces persistent failures out to sixteen seconds.
      backoffUnit: Duration = .milliseconds(500)
    ) {
      self.response = response
      self.grace = grace
      self.backoffUnit = backoffUnit
    }
  }

  private let policy: SessionPolicy
  private let opener: any TandemChannelOpening
  private let verifier: any DeviceVerifying
  private let timeouts: Timeouts
  private let router = TandemRouter()

  private var state = SessionState.released
  private var epoch = SessionEpoch(0)
  private var nextOperation = OperationID(0)

  private var channel: (any TandemChannel)?
  private var parser = FrameStreamParser()
  private var profile: TandemVerifiedDeviceProfile?
  private var fingerprint: TandemDeviceFingerprint?
  private var rejection: TandemDeviceVerificationFailure?
  private var latestReadings = DeviceReadings()
  private var readingTask: Task<Void, Never>?
  private let reader = FeatureReader()

  /// The one request currently on the wire. Requests are strictly serialized: the
  /// shared acknowledgement and the alternating sequence number leave no way to
  /// attribute interleaved traffic, so a second request never starts until the
  /// current one has resolved.
  private var inFlight: PendingRequest?
  /// True from the moment a sender claims the wire until its request resolves.
  private var isSending = false
  /// Senders waiting for the wire, resumed strictly in arrival order.
  private var sendWaiters: [CheckedContinuation<Void, Never>] = []
  /// Whether the caveated write path is open for a device that failed verification.
  /// Decided once per verification from the failure and the fingerprint: an unknown
  /// model or firmware that passes the experimental gate may be written to behind
  /// the caveat; a structural refusal keeps its reads but never becomes writable.
  private var unverifiedWritesPermitted = false
  /// Alternates 0 and 1 across everything we send on a channel.
  private var outgoingSequence: UInt8 = 0
  private var notifications: AsyncStream<TandemFrame>.Continuation?
  private var closeWasRequested = false
  /// Touch-panel gesture names heard over the session, added to the support report.
  /// They are announced, never readable, so the log is the only record of them.
  private var gestureLog = TandemGestureNotificationLog()

  private var openTask: Task<Void, Never>?
  private var inboundTask: Task<Void, Never>?
  private var graceTask: Task<Void, Never>?
  private var backoffTask: Task<Void, Never>?
  private var verificationTask: Task<Void, Never>?

  public init(
    policy: SessionPolicy = SessionPolicy(),
    opener: any TandemChannelOpening,
    verifier: any DeviceVerifying,
    timeouts: Timeouts = Timeouts()
  ) {
    self.policy = policy
    self.opener = opener
    self.verifier = verifier
    self.timeouts = timeouts
  }

  public var phase: SessionState.Phase { state.phase }
  /// The unverified phase admits writes only when verification chose the caveated
  /// experimental path; a device it refused stays readable but never writable.
  public var acceptsWrites: Bool {
    state.acceptsWrites && (state.phase != .unverified || unverifiedWritesPermitted)
  }
  public var verifiedProfile: TandemVerifiedDeviceProfile? { profile }
  /// Available whether or not the device turned out to be controllable.
  public var deviceFingerprint: TandemDeviceFingerprint? { fingerprint }
  public var unsupportedReason: TandemDeviceVerificationFailure? { rejection }
  public var readings: DeviceReadings { latestReadings }

  /// Everything a panel refresh needs, read in one actor hop so the fields are always
  /// of the same instant. Taken one accessor at a time, an `invalidate()` could land
  /// between them and hand the panel a `.ready` phase with a nil fingerprint for a
  /// frame; with device-scoped rules that momentary nil model name unmatched a rule and
  /// set noise/EQ flapping. A single hop cannot be interrupted.
  public struct Snapshot: Sendable {
    public let phase: SessionState.Phase
    public let fingerprint: TandemDeviceFingerprint?
    public let unsupportedReason: TandemDeviceVerificationFailure?
    public let acceptsWrites: Bool
    public let readings: DeviceReadings
  }

  public var snapshot: Snapshot {
    Snapshot(
      phase: state.phase,
      fingerprint: fingerprint,
      unsupportedReason: rejection,
      acceptsWrites: acceptsWrites,
      readings: latestReadings
    )
  }

  public private(set) lazy var deviceNotifications: AsyncStream<TandemFrame> = {
    let (stream, continuation) = AsyncStream<TandemFrame>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    notifications = continuation
    return stream
  }()

  // MARK: - Events

  public func handle(_ event: SessionEvent) async {
    let previous = state.phase
    let (next, effects) = policy.reduce(state, event)
    state = next
    for effect in effects {
      await run(effect)
    }
    reconcilePolling(from: previous)
  }

  /// The suspended grace holds the channel but must not keep talking on it: the
  /// user is no longer listening here, so the poll pauses on the way in and resumes
  /// when the device becomes the output again. The session itself — epoch, channel,
  /// fingerprint, readings — is left intact, which is the whole point of the grace.
  private func reconcilePolling(from previous: SessionState.Phase) {
    let wasSuspended = previous.isSuspended
    let isSuspended = state.phase.isSuspended
    if isSuspended, !wasSuspended {
      readingTask?.cancel()
      readingTask = nil
    } else if wasSuspended, state.phase == .ready || state.phase == .unverified {
      startReading()
    }
  }

  // MARK: - Effects

  private func run(_ effect: SessionEffect) async {
    switch effect {
    case .openChannel(let device, let attempt):
      startOpening(device, attempt: attempt)

    case .cancelOpen:
      openTask?.cancel()
      openTask = nil

    case .closeChannel:
      closeWasRequested = true
      let closing = channel
      channel = nil
      await closing?.close()

    case .invalidateSession:
      invalidate()

    case .failPendingRequests:
      failPending(with: .sessionInvalidated)

    case .startVerification:
      startVerification()

    case .startGrace:
      graceTask?.cancel()
      graceTask = Task { [timeouts] in
        try? await Task.sleep(for: timeouts.grace)
        guard !Task.isCancelled else { return }
        await self.handle(.graceExpired)
      }

    case .cancelGrace:
      graceTask?.cancel()
      graceTask = nil

    case .scheduleBackoff(let attempt):
      backoffTask?.cancel()
      let delay = timeouts.backoffUnit * Double(1 << min(attempt - 1, 5))
      backoffTask = Task {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        await self.handle(.backoffExpired)
      }

    case .cancelBackoff:
      backoffTask?.cancel()
      backoffTask = nil
    }
  }

  private func invalidate() {
    readingTask?.cancel()
    readingTask = nil
    latestReadings = DeviceReadings()
    epoch = epoch.next
    parser = FrameStreamParser()
    profile = nil
    // The fingerprint describes the device on the other end of a live session. Once the
    // session is torn down (disconnect, contention, fault) there is no such device, so
    // it is cleared along with the readings; otherwise the panel keeps showing the last
    // device's name and battery after it is gone. The unverified phase does not invalidate,
    // so a connected-but-unverified device still keeps its fingerprint and caveat.
    fingerprint = nil
    rejection = nil
    unverifiedWritesPermitted = false
    outgoingSequence = 0
    // The gestures heard belong to the device that announced them. Carrying the log
    // across an invalidation would mix the previous device's touch vocabulary into
    // the next device's support report.
    gestureLog = TandemGestureNotificationLog()
    inboundTask?.cancel()
    inboundTask = nil
    verificationTask?.cancel()
    verificationTask = nil
  }

  // MARK: - Channel

  private func startOpening(_ device: DeviceIdentity, attempt: ConnectionAttempt) {
    openTask?.cancel()
    closeWasRequested = false
    openTask = Task {
      do {
        let opened = try await opener.open(device)
        await self.channelOpened(opened, attempt: attempt)
      } catch ChannelFailure.openTimedOut {
        // The transport confirms the baseband connection before opening, so a
        // timeout means a reachable device let the open hang — which is how this
        // hardware behaves while another host holds its single control channel.
        // An unreachable or unpaired device fails fast with a different error and
        // stays on the ordinary retry path.
        await self.handle(.controlContended(attempt))
      } catch {
        await self.handle(.channelFailed(attempt))
      }
    }
  }

  private func channelOpened(_ opened: OpenedChannel, attempt: ConnectionAttempt) async {
    // Ask the policy first. It may have moved on, in which case it tells us to close
    // rather than adopt the channel.
    let (next, effects) = policy.reduce(state, .channelOpened(attempt))
    guard next.phase == .verifying else {
      state = next
      await opened.channel.close()
      for effect in effects where !effect.isChannelClose { await run(effect) }
      return
    }

    channel = opened.channel
    parser = FrameStreamParser()
    startReading(opened.inbound, attempt: attempt)
    state = next
    for effect in effects { await run(effect) }
  }

  private func startReading(_ inbound: AsyncStream<Data>, attempt: ConnectionAttempt) {
    inboundTask?.cancel()
    inboundTask = Task {
      for await chunk in inbound {
        await self.ingest(chunk)
      }
      await self.channelDidClose(attempt: attempt)
    }
  }

  private func channelDidClose(attempt: ConnectionAttempt) async {
    if closeWasRequested {
      closeWasRequested = false
      await handle(.channelClosedByUs)
    } else {
      await handle(.channelClosedUnexpectedly(attempt))
    }
  }

  private func ingest(_ chunk: Data) async {
    let parsed = parser.append(chunk)
    if !parsed.discards.isEmpty {
      // Damaged input is survivable; a stream we can no longer interpret is not.
      for discard in parsed.discards where discard.isFatal {
        await handle(.sessionFault(.bufferOverflowed))
        return
      }
    }

    let routed = router.route(parsed.frames)
    for ack in routed.acknowledgements {
      try? await channel?.write(ack.encoded())
    }
    for event in routed.events {
      deliver(event)
    }
  }

  private func deliver(_ event: InboundEvent) {
    switch event {
    case .acknowledgement:
      // Requests are serialized, so an acknowledgement can only belong to the one
      // in flight — and only when that request was sent on this session.
      if inFlight?.epoch == epoch {
        inFlight?.lifecycle.handle(.acknowledgementReceived)
      }

    case .data(let frame):
      guard var request = inFlight, request.epoch == epoch, request.matches(frame) else {
        applyUnsolicited(frame)
        gestureLog = gestureLog.recording(frame.payload)
        notifications?.yield(frame)
        return
      }
      request.lifecycle.handle(.responseReceived(frame))
      inFlight = nil
      endSendTurn()
      request.continuation.resume(returning: frame)
    }
  }

  /// A setting changed on the device itself — a touch on the headset, or a change made
  /// from the phone app — is announced over the channel as an unsolicited frame, not as
  /// a reply to a request. The periodic read folds such a change in eventually, but only
  /// on its slow keepalive cadence (up to a reading interval later), which is why a
  /// noise-control change made by touch took many seconds to reach the panel. Parsing
  /// the notification here updates the reading at once, so the panel reflects a physical
  /// change within a refresh tick.
  ///
  /// Only a noise-control parameter — what a headphone touch actually changes — is
  /// handled; every other unsolicited frame is left untouched for the notification
  /// stream and the gesture log. The reading's shape (modes, field count, wind kind) is
  /// carried over from what was read, since the notification alone does not restate it.
  private func applyUnsolicited(_ frame: TandemFrame) {
    guard let reading = latestReadings.noiseControl else { return }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= 2, bytes[1] == reading.inquiry else { return }
    // The device announces a noise-control change with either the return (0x67) or the
    // notify (0x69) command — the same two the write's read-back listens for.
    let state: TandemNoiseControlState
    switch bytes[0] {
    case 0x67:
      guard
        let parsed = try? TandemNoiseControlProtocol.parseParameterResponse(
          frame, inquiry: reading.inquiry)
      else { return }
      state = parsed
    case 0x69:
      guard
        let parsed = try? TandemNoiseControlProtocol.parseParameterNotification(
          frame, inquiry: reading.inquiry)
      else { return }
      state = parsed
    default:
      return
    }
    guard state != reading.state else { return }
    latestReadings.noiseControl = NoiseControlReading(
      inquiry: reading.inquiry,
      modes: reading.modes,
      state: state,
      valueFieldCount: max(bytes.count - 2, reading.valueFieldCount),
      legacyWindKind: reading.inquiry == TandemNoiseControlProtocol.legacyInquiry && bytes.count > 3
        ? bytes[3] : reading.legacyWindKind
    )
  }

  private func failPending(with failure: RequestFailure) {
    // Waiting senders are not failed here: each re-checks the session when its turn
    // comes and fails itself if the session has moved on underneath it.
    guard let request = inFlight else { return }
    inFlight = nil
    endSendTurn()
    request.continuation.resume(throwing: SessionRequestFailure.failed(failure))
  }

  // MARK: - Verification

  private func startVerification() {
    verificationTask?.cancel()
    // The verifier is not obliged to notice cancellation, so a verification can
    // outlive the session it was started for. Both completions carry the epoch they
    // were admitted under and are dropped if the session has moved on: without the
    // guard, an old session's result would stamp its fingerprint on the new one, and
    // an old verification failing over — its requests die with `sessionInvalidated`
    // — would fail the new session's verification for it.
    let admittedEpoch = epoch
    verificationTask = Task {
      do {
        let outcome = try await self.verifier.verify(over: Requester(coordinator: self))
        await self.verificationFinished(outcome, from: admittedEpoch)
      } catch {
        // Reaching the device failed, which is not the same as the device being
        // unsupported: one is worth retrying, the other never is. The task inherits
        // the coordinator's isolation, so the epoch read is a plain same-actor call.
        guard self.epoch == admittedEpoch else { return }
        await self.handle(.verificationFailedTransient)
      }
    }
  }

  private func verificationFinished(
    _ outcome: VerificationOutcome,
    from admittedEpoch: SessionEpoch
  ) async {
    guard admittedEpoch == epoch else { return }
    fingerprint = outcome.fingerprint
    switch outcome {
    case .verified(let verified, _):
      profile = verified
      rejection = nil
      unverifiedWritesPermitted = false
      await handle(.verificationSucceeded)
    case .unsupported(let rejectedFingerprint, let reason):
      profile = nil
      rejection = reason
      // Which side of the caveat the device lands on is decided here, once, from
      // the registry's contract: an unknown model or firmware may be driven
      // experimentally when the gate recognises it; a structural refusal may not.
      unverifiedWritesPermitted = TandemVerifiedDeviceRegistry.permitsUnverifiedWrites(
        for: rejectedFingerprint, rejectedWith: reason
      )
      await handle(.verificationRejected)
    }
    // Reads follow from what the device declared, so they run whether or not it is
    // one this application may write to.
    startReading()
  }

  /// Polls the values the device offered. A device that reports changes without being
  /// asked will make this redundant, but nothing may depend on notifications that a
  /// given model might never send.
  private func startReading() {
    readingTask?.cancel()
    guard let functions = fingerprint?.table1Functions else { return }
    let dialect = fingerprint?.dialect ?? .current
    // The older generation closes a control channel it has not heard from in about
    // fifteen seconds, so its poll doubles as a keepalive and runs well inside that.
    let interval: Duration =
      timeouts.readingIntervalOverride ?? (dialect == .legacy ? .seconds(8) : .seconds(20))
    let admittedEpoch = epoch
    readingTask = Task { [reader] in
      while !Task.isCancelled {
        let readings = await reader.read(
          declaring: functions,
          dialect: dialect,
          over: Requester(coordinator: self)
        )
        // A cancelled cycle must not store: pausing for `suspended` cancels this
        // task without moving the epoch, and the partial result of the interrupted
        // cycle would erase fields the session still holds.
        guard !Task.isCancelled else { return }
        // The task inherits the coordinator's isolation, so the store is a plain
        // same-actor call; the reads above are where the suspensions happen.
        self.store(readings, from: admittedEpoch)
        try? await Task.sleep(for: interval)
      }
    }
  }

  private func store(_ readings: DeviceReadings, from readEpoch: SessionEpoch) {
    // A read can outlive the session it was started for: `FeatureReader` swallows
    // per-request failures, so a read interrupted by an invalidation still returns a
    // partial result afterwards. Storing that would resurrect the previous device's
    // values — and let a write against the next device pass `apply`'s guards with
    // the previous device's inquiry and field count.
    guard readEpoch == epoch else { return }
    latestReadings = readings
  }

  /// The raw read-only capability exchanges for a support report, gathered over the
  /// session's own request path, gated on the functions the device declared.
  /// What the gesture log holds right now. The report UI polls this during its
  /// listening window to show the user each touch as it is heard.
  public func gestureCaptures() -> [TandemRawCapture] {
    gestureLog.captures
  }

  public func supportCaptures() async -> [TandemRawCapture] {
    guard let functions = fingerprint?.table1Functions else { return [] }
    let read = await DeviceDiagnostics().rawCaptures(
      declaring: functions,
      over: Requester(coordinator: self)
    )
    // The gesture names heard so far ride along: they show the touch vocabulary the
    // report cannot ask the device for.
    return read + gestureLog.captures
  }

  // MARK: - Writing

  public enum WriteFailure: Error, Equatable, Sendable {
    case notPermitted
    case unsupported
    /// The device answered, but with something other than what was asked for. The
    /// value in hand is what it actually holds.
    case notApplied(TandemNoiseControlState)
    case notAppliedListening(TandemListeningSelection)
    /// The equaliser read-back did not hold the requested preset or bands. The values
    /// carried are what the device actually holds.
    case notAppliedEqualizer(selectedPreset: UInt8?, bandSteps: [Int])
    /// The speak-to-chat read-back did not hold the requested values.
    case notAppliedSpeakToChat(SpeakToChatReading)
    /// The sidetone read-back did not hold the requested value. What is carried is
    /// what the device actually holds.
    case notAppliedSidetone(SidetoneReading)
    case failed(SessionRequestFailure)
  }

  /// Sends a noise-control change and reads it back.
  ///
  /// The read-back is the only check there is on an unverified model: the encoding
  /// came from a different device, so what the headset did with it has to be observed
  /// rather than assumed.
  /// `isFinal` is false for the intermediate values of a drag. Those are sent so the
  /// listener hears the change as they move, but they are not read back: verifying
  /// every step would flood the channel and lag behind the finger. The read-back
  /// happens once, on the value the drag settles on.
  public func apply(noiseControl target: TandemNoiseControlState, isFinal: Bool = true) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.noiseControl else {
      throw WriteFailure.unsupported
    }
    let inquiry = reading.inquiry
    let fieldCount = reading.valueFieldCount
    let windKind = reading.legacyWindKind

    // Intermediate drag values are fired without waiting, so a step the device does
    // not acknowledge cannot time out and fault the session.
    guard isFinal else {
      try? await writeWithoutReply {
        try TandemNoiseControlProtocol.setParameterRequest(
          sequence: $0,
          inquiry: inquiry,
          state: target,
          isFinal: false,
          valueFieldCount: fieldCount,
          legacyWindKind: windKind
        )
      }
      return
    }

    do {
      _ = try await send(
        {
          try TandemNoiseControlProtocol.setParameterRequest(
            sequence: $0,
            inquiry: inquiry,
            state: target,
            isFinal: true,
            valueFieldCount: fieldCount,
            legacyWindKind: windKind
          )
        },
        // The headset answers a change with a notification rather than a reply.
        matching: { frame in
          let bytes = [UInt8](frame.payload)
          return bytes.count >= 2 && (bytes[0] == 0x69 || bytes[0] == 0x67) && bytes[1] == inquiry
        }
      )
    } catch let failure as SessionRequestFailure {
      throw WriteFailure.failed(failure)
    }

    let confirmed = try await readNoiseControlNow(inquiry)
    latestReadings.noiseControl = confirmed
    guard confirmed.state == target else {
      throw WriteFailure.notApplied(confirmed.state)
    }
  }

  /// Selects a listening mode and reads it back.
  ///
  /// Each feature is set with a fire-and-forget write, so a model that does not answer
  /// a set cannot time out and fault the session; the read-back that follows is a plain
  /// parameter request, which every model answers. The features are only ever those the
  /// device declared, so a device without listening modes is never written to here.
  public func apply(listeningSelection target: TandemListeningSelection) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.listeningMode, !reading.features.isEmpty else {
      throw WriteFailure.unsupported
    }

    let room: TandemListeningRoom
    if case .backgroundMusic(let selected) = target { room = selected } else { room = reading.savedRoom }

    // Turn off the modes that should be off before turning the target on, so the device
    // is never briefly asked to hold two at once.
    let ordered = reading.features.filter { !shouldBeOn($0, in: target) }
      + reading.features.filter { shouldBeOn($0, in: target) }
    for feature in ordered {
      let on = shouldBeOn(feature, in: target)
      try? await writeWithoutReply {
        try TandemListeningModeProtocol.setRequest(
          sequence: $0, feature: feature, on: on, room: room
        )
      }
    }

    let confirmed = try await readListeningNow(features: reading.features)
    latestReadings.listeningMode = confirmed
    guard confirmed.selection == target else {
      throw WriteFailure.notAppliedListening(confirmed.selection)
    }
  }

  private func shouldBeOn(_ feature: TandemListeningFeature, in target: TandemListeningSelection) -> Bool {
    switch (feature.kind, target) {
    case (.backgroundMusic, .backgroundMusic): true
    case (.cinema, .cinema): true
    default: false
    }
  }

  private func readListeningNow(
    features: [TandemListeningFeature]
  ) async throws -> TandemListeningReading {
    var states: [UInt8: TandemListeningFeatureState] = [:]
    for feature in features {
      let frame = try await send(
        { try TandemListeningModeProtocol.parameterRequest(sequence: $0, inquiry: feature.inquiry) },
        matching: { candidate in
          let bytes = [UInt8](candidate.payload)
          return bytes.count >= 2 && bytes[0] == 0xE7 && bytes[1] == feature.inquiry
        }
      )
      if let state = try? TandemListeningModeProtocol.parseParameterResponse(frame, feature: feature) {
        states[feature.inquiry] = state
      }
    }
    return TandemListeningReading.resolve(features: features, states: states)
  }

  /// Selects an equaliser preset or writes custom band levels, then reads back what the
  /// device holds and reports a value that did not take. `isFinal` is false for the
  /// intermediate steps of a band drag, which are fired without a read-back so the sound
  /// follows the finger without flooding the channel. Only ever reached for a device that
  /// declared the equaliser.
  public func apply(
    equalizerPreset presetIdentifier: UInt8,
    bandSteps: [UInt8],
    isFinal: Bool = true
  ) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.equalizer else { throw WriteFailure.unsupported }
    let inquiry = TandemReadOnlyEqualizer.inquiry(for: fingerprint?.dialect ?? .current)
    // The older generation writes band levels against "the current preset" (0xFF)
    // rather than a named one; the preset itself was selected by an earlier write.
    let presetByte: UInt8 =
      inquiry == TandemReadOnlyEqualizer.legacyInquiry && !bandSteps.isEmpty
      ? 0xFF : presetIdentifier

    // The set is fire-and-forget like the listening writes: a model that answers a
    // set only with a notification must not time the session out. What the device
    // actually did is established by the read-back below.
    try? await writeWithoutReply {
      try TandemReadOnlyEqualizer.setParameterRequest(
        sequence: $0,
        presetIdentifier: presetByte,
        bandSteps: bandSteps,
        inquiry: inquiry
      )
    }
    guard isFinal else { return }

    let confirmed = try await readEqualizerParameterNow(reading)
    latestReadings.equalizer = confirmed
    // A preset selection is judged on the preset; a band write on the bands. The
    // preset byte of a legacy band write is an addressing detail ("the current
    // preset"), so the bands are the requested value there.
    let applied =
      bandSteps.isEmpty
      ? confirmed.selectedPreset == presetIdentifier
      : confirmed.bandSteps == bandSteps.map(Int.init)
    guard applied else {
      throw WriteFailure.notAppliedEqualizer(
        selectedPreset: confirmed.selectedPreset,
        bandSteps: confirmed.bandSteps
      )
    }
  }

  /// Turns speak-to-chat on or off, preserving the device's unverified second field,
  /// then reads back what it holds and reports a value that did not take. Only reached
  /// for a device that declared the feature. The set is fire-and-forget for the same
  /// reason as the listening writes; the read-back is the check.
  public func apply(speakToChatEnabled isEnabled: Bool) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.speakToChat else { throw WriteFailure.unsupported }
    try? await writeWithoutReply {
      try TandemSpeakToChatProtocol.setEnabledRequest(
        sequence: $0,
        inquiry: reading.inquiry,
        isEnabled: isEnabled,
        secondarySettingEnabled: reading.secondarySettingEnabled
      )
    }
    let confirmed = try await readSpeakToChatNow(reading)
    latestReadings.speakToChat = confirmed
    guard confirmed.isEnabled == isEnabled else {
      throw WriteFailure.notAppliedSpeakToChat(confirmed)
    }
  }

  public func apply(
    speakToChatSensitivity sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout
  ) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.speakToChat else { throw WriteFailure.unsupported }
    try? await writeWithoutReply {
      try TandemSpeakToChatProtocol.setDetailRequest(
        sequence: $0,
        inquiry: reading.inquiry,
        sensitivity: sensitivity,
        timeout: timeout
      )
    }
    let confirmed = try await readSpeakToChatNow(reading)
    latestReadings.speakToChat = confirmed
    guard confirmed.sensitivity == sensitivity, confirmed.timeout == timeout else {
      throw WriteFailure.notAppliedSpeakToChat(confirmed)
    }
  }

  /// Turns call-time sidetone on or off, then reads back what the device holds and
  /// reports a value that did not take. Only ever reached for a device whose declared
  /// general-setting slot named sidetone — the slot itself came from the reading, so
  /// no slot number is assumed here. The set is fire-and-forget for the same reason
  /// as the listening writes; the read-back is the check.
  public func apply(sidetoneEnabled isEnabled: Bool) async throws {
    guard acceptsWrites else { throw WriteFailure.notPermitted }
    guard let reading = latestReadings.sidetone, reading.isEnabled != nil else {
      throw WriteFailure.unsupported
    }
    try? await writeWithoutReply {
      try TandemGeneralSettingProtocol.setParameterRequest(
        sequence: $0,
        slot: reading.slot,
        value: .boolean(isEnabled)
      )
    }
    let confirmed = try await readSidetoneNow(reading)
    latestReadings.sidetone = confirmed
    guard confirmed.isEnabled == isEnabled else {
      throw WriteFailure.notAppliedSidetone(confirmed)
    }
  }

  private func readSidetoneNow(_ reading: SidetoneReading) async throws -> SidetoneReading {
    let slot = reading.slot
    let frame = try await send(
      { try TandemGeneralSettingProtocol.parameterRequest(sequence: $0, slot: slot) },
      matching: { candidate in
        let bytes = [UInt8](candidate.payload)
        return bytes.count >= 2 && bytes[0] == 0xD7 && bytes[1] == slot.rawValue
      }
    )
    let value = try TandemGeneralSettingProtocol.parseParameterResponse(
      frame, capability: reading.snapshot.capability
    )
    return SidetoneReading(
      slot: slot,
      snapshot: TandemGeneralSettingSnapshot(
        capability: reading.snapshot.capability,
        isControlEnabled: reading.snapshot.isControlEnabled,
        value: value
      )
    )
  }

  private func readSpeakToChatNow(_ reading: SpeakToChatReading) async throws -> SpeakToChatReading {
    let inquiry = reading.inquiry
    let parameterFrame = try await send(
      { try TandemSpeakToChatProtocol.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: { candidate in
        let bytes = [UInt8](candidate.payload)
        return bytes.count >= 2 && bytes[0] == 0xF7 && bytes[1] == inquiry
      }
    )
    let parameters = try TandemSpeakToChatProtocol.parseParameterResponse(parameterFrame, inquiry: inquiry)

    let detailFrame = try await send(
      { try TandemSpeakToChatProtocol.extendedParameterRequest(sequence: $0, inquiry: inquiry) },
      matching: { candidate in
        let bytes = [UInt8](candidate.payload)
        return bytes.count >= 2 && bytes[0] == 0xFB && bytes[1] == inquiry
      }
    )
    let detail = try TandemSpeakToChatProtocol.parseExtendedParameterResponse(detailFrame, inquiry: inquiry)

    return SpeakToChatReading(
      inquiry: inquiry,
      capability: reading.capability,
      isEnabled: parameters.isEnabled,
      secondarySettingEnabled: parameters.secondarySettingEnabled,
      sensitivity: detail.sensitivity,
      timeout: detail.timeout
    )
  }

  private func readEqualizerParameterNow(_ reading: EqualizerReading) async throws -> EqualizerReading {
    let capability = TandemEqualizerCapability(
      bandCount: reading.bandCount,
      levelStepCount: reading.levelStepCount,
      presets: reading.presets.map { TandemEqualizerPreset(identifier: $0.identifier, name: $0.name ?? "") }
    )
    let inquiry = TandemReadOnlyEqualizer.inquiry(for: fingerprint?.dialect ?? .current)
    let frame = try await send(
      { try TandemReadOnlyEqualizer.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: { candidate in
        let bytes = [UInt8](candidate.payload)
        return bytes.count >= 2 && bytes[0] == 0x57 && bytes[1] == inquiry
      }
    )
    let params = try TandemReadOnlyEqualizer.parseParameterResponse(
      frame, capability: capability, inquiry: inquiry
    )
    return EqualizerReading(
      presets: reading.presets,
      selectedPreset: params.presetIdentifier,
      bandFrequencies: reading.bandFrequencies,
      bandSteps: params.bandSteps.map(Int.init),
      stepRange: reading.stepRange,
      flatStep: reading.flatStep
    )
  }

  private func readNoiseControlNow(_ inquiry: UInt8) async throws -> NoiseControlReading {
    let frame = try await send(
      { try TandemNoiseControlProtocol.parameterRequest(sequence: $0, inquiry: inquiry) },
      matching: { candidate in
        let bytes = [UInt8](candidate.payload)
        return bytes.count >= 2 && bytes[0] == 0x67 && bytes[1] == inquiry
      }
    )
    let confirmed = try TandemNoiseControlProtocol.parseParameterResponse(frame, inquiry: inquiry)
    let existing = latestReadings.noiseControl
    let bytes = [UInt8](frame.payload)
    return NoiseControlReading(
      inquiry: inquiry,
      modes: existing?.modes ?? [],
      state: confirmed,
      valueFieldCount: max(frame.payload.count - 2, existing?.valueFieldCount ?? 0),
      legacyWindKind: inquiry == TandemNoiseControlProtocol.legacyInquiry && bytes.count > 3
        ? bytes[3]
        : (existing?.legacyWindKind ?? 0)
    )
  }

  // MARK: - Requests

  /// Writes a frame and returns without waiting for anything back.
  ///
  /// For the intermediate values of a drag: the device may answer only the final
  /// change, so waiting for a reply on each step would time out, and a timeout is read
  /// as a session fault that tears the session down. The listener still hears the
  /// change; the settled value is what gets confirmed.
  fileprivate func writeWithoutReply(
    _ build: @Sendable (UInt8) throws -> TandemFrame
  ) async throws {
    // `suspended` is refused although the channel is open: the device is no longer
    // the output, so nothing may be sent into the grace period — a write there
    // would previously go out and then fail silently on the read-back.
    switch state.phase {
    case .verifying, .ready, .unverified:
      break
    default:
      throw SessionRequestFailure.notReady
    }
    guard let channel else { throw SessionRequestFailure.channel(.closed) }

    let frame: TandemFrame
    do {
      frame = try build(outgoingSequence)
    } catch {
      throw SessionRequestFailure.notReady
    }
    outgoingSequence ^= 1

    do {
      try await channel.write(frame.encoded())
    } catch let failure as ChannelFailure {
      throw SessionRequestFailure.channel(failure)
    }
  }

  /// Internal rather than fileprivate so the serialization and attribution can be
  /// exercised directly by tests; production callers still go through the features.
  func send(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool,
    faultsOnTimeout: Bool = true
  ) async throws -> TandemFrame {
    // Checked before queueing so a request against a session that is already gone
    // fails now rather than after waiting its turn behind the request in flight.
    _ = try checkRequestAdmission()
    let admittedEpoch = epoch
    await claimSendTurn()
    return try await performSend(
      build,
      matching: matching,
      faultsOnTimeout: faultsOnTimeout,
      admittedEpoch: admittedEpoch
    )
  }

  /// Verification runs before `ready`, so it is admitted too; nothing else is.
  /// `suspended` is refused although the channel is open: the grace period holds
  /// the channel precisely so nothing has to travel on it, and admitting requests
  /// there would keep the readings poll talking to a device nobody is listening to.
  private func checkRequestAdmission() throws -> any TandemChannel {
    switch state.phase {
    case .verifying, .ready, .unverified:
      break
    default:
      throw SessionRequestFailure.notReady
    }
    guard let channel else { throw SessionRequestFailure.channel(.closed) }
    return channel
  }

  /// Waits until the wire is free. First come, first served: waiters are resumed in
  /// arrival order, so requests reach the device in the order they were made.
  private func claimSendTurn() async {
    guard isSending else {
      isSending = true
      return
    }
    await withCheckedContinuation { sendWaiters.append($0) }
  }

  /// Passes the wire to the next waiter, or frees it. Every terminal path of the
  /// request in flight ends here; missing one would stall every later request.
  private func endSendTurn() {
    guard sendWaiters.isEmpty else {
      // The turn passes directly, so `isSending` stays true for the successor.
      sendWaiters.removeFirst().resume()
      return
    }
    isSending = false
  }

  private func performSend(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool,
    faultsOnTimeout: Bool,
    admittedEpoch: SessionEpoch
  ) async throws -> TandemFrame {
    // Everything is re-checked after the wait: the session may have been torn down
    // or rebuilt while this request was queued, and a request admitted against the
    // old session must not write into its successor.
    let channel: any TandemChannel
    do {
      guard admittedEpoch == epoch else {
        throw SessionRequestFailure.failed(.sessionInvalidated)
      }
      channel = try checkRequestAdmission()
    } catch {
      endSendTurn()
      throw error
    }

    let frame: TandemFrame
    do {
      frame = try build(outgoingSequence)
    } catch {
      endSendTurn()
      throw SessionRequestFailure.notReady
    }
    outgoingSequence ^= 1

    let id = nextOperation
    nextOperation = nextOperation.next

    return try await withCheckedThrowingContinuation { continuation in
      inFlight = PendingRequest(
        lifecycle: RequestLifecycle(id: id),
        epoch: admittedEpoch,
        matches: matching,
        continuation: continuation,
        faultsOnTimeout: faultsOnTimeout
      )
      Task {
        do {
          try await channel.write(frame.encoded())
        } catch let failure as ChannelFailure {
          await self.finish(id, with: .channel(failure))
          return
        } catch {
          await self.finish(id, with: .channel(.closed))
          return
        }
        await self.scheduleResponseTimeout(id)
      }
    }
  }

  /// Whether the request currently on the wire has been acknowledged. Exposed for
  /// tests: acknowledgement handling has no other observable surface.
  var inFlightAcknowledged: Bool? { inFlight?.lifecycle.isAcknowledged }

  private func scheduleResponseTimeout(_ id: OperationID) async {
    Task { [timeouts] in
      try? await Task.sleep(for: timeouts.response)
      await self.responseTimedOut(id)
    }
  }

  private func responseTimedOut(_ id: OperationID) async {
    guard var request = inFlight, request.lifecycle.id == id else { return }
    inFlight = nil
    endSendTurn()
    request.lifecycle.handle(.responseTimedOut)
    guard case .failed(let failure) = request.lifecycle.outcome else { return }
    request.continuation.resume(throwing: SessionRequestFailure.failed(failure))
    guard request.faultsOnTimeout else { return }
    // An unanswered request leaves us unable to attribute anything that arrives
    // later, so the session is rebuilt rather than continued. A probe opts out: it
    // expects some functions to go unanswered and must not tear down a working
    // session to discover that.
    await handle(.sessionFault(.responseTimedOut))
  }

  private func finish(_ id: OperationID, with failure: SessionRequestFailure) async {
    guard let request = inFlight, request.lifecycle.id == id else { return }
    inFlight = nil
    endSendTurn()
    request.continuation.resume(throwing: failure)
  }

  private struct PendingRequest {
    var lifecycle: RequestLifecycle
    var epoch: SessionEpoch
    let matches: @Sendable (TandemFrame) -> Bool
    let continuation: CheckedContinuation<TandemFrame, Error>
    /// False for a probe, whose timeout fails only itself; true for a request, whose
    /// timeout rebuilds the session.
    let faultsOnTimeout: Bool

    func matches(_ frame: TandemFrame) -> Bool { matches(frame) }
  }

  private struct Requester: SessionRequesting {
    let coordinator: SessionCoordinator

    func request(
      _ build: @Sendable (UInt8) throws -> TandemFrame,
      matching: @Sendable @escaping (TandemFrame) -> Bool
    ) async throws -> TandemFrame {
      try await coordinator.send(build, matching: matching)
    }

    func probe(
      _ build: @Sendable (UInt8) throws -> TandemFrame,
      matching: @Sendable @escaping (TandemFrame) -> Bool
    ) async throws -> TandemFrame {
      try await coordinator.send(build, matching: matching, faultsOnTimeout: false)
    }
  }
}

extension SessionEffect {
  fileprivate var isChannelClose: Bool {
    if case .closeChannel = self { return true }
    return false
  }
}

extension SessionState.Phase {
  fileprivate var isSuspended: Bool {
    if case .suspended = self { return true }
    return false
  }
}

extension FrameStreamParser.Discard {
  /// Losing a whole oversized body means the stream position is no longer trusted.
  fileprivate var isFatal: Bool {
    if case .oversized = self { return true }
    return false
  }
}
