import BoseCore
import Foundation

/// The BMAP request layer: one actor that drains a transport continuously, serialises
/// requests onto it, and shapes them into the operation kinds a BMAP device needs.
///
/// It is the Bose counterpart to Sony's `SessionCoordinator`, and borrows only that
/// design's proven ideas — a single in-flight request behind a FIFO wire gate, and an
/// injected seam for everything with hardware or timing in it — not its types. BMAP is
/// a different protocol: no acknowledgements, no sequence numbers, so a request is
/// terminated by the *operator* of the answer (STATUS / RESULT / ERROR) rather than by
/// an ack, and PROCESSING means "keep waiting".
///
/// Timing runs entirely on an injected `SessionClock`: the settle window between sends,
/// response timeouts, and the drain's idle cutoff are all clock deadlines, so the whole
/// layer is testable against a `TestSessionClock` without waiting real time. Receiving
/// is always on — the drain loop never pauses for a send — so an unsolicited STATUS
/// that arrives before or between requests is delivered to `notifications`, never lost.
public actor BoseSession {
  /// Timing knobs. None are model-specific: they are BMAP-level pacing and deadlines,
  /// so they live here as defaults rather than in `BoseDeviceConfig`.
  public struct Settings: Sendable {
    /// Minimum interval between two sends. Coalesces bursts the way the UI's 90 ms drag
    /// debounce does upstream, and gives a written value a moment to settle before a
    /// read-back GET goes out.
    public var settleWindow: Duration
    /// How long a single request waits for a terminal answer.
    public var responseTimeout: Duration
    /// A drain ends once this long passes with no further related frame (frozen spec §3).
    public var drainIdle: Duration
    /// A drain never runs longer than this in total, however busy the stream stays.
    public var drainOverall: Duration
    /// How many read-back GETs a write-then-poll tries before reporting `notApplied`.
    public var maxReadBackPolls: Int
    /// How many times connect resends the init before giving up (frozen spec §2: the
    /// device can stay silent until it has been pinged, so a resend is expected).
    public var maxConnectAttempts: Int
    /// How long connect waits for a response to each init before resending.
    public var connectResponseTimeout: Duration

    public init(
      settleWindow: Duration = .milliseconds(90),
      responseTimeout: Duration = .seconds(5),
      drainIdle: Duration = .milliseconds(500),
      drainOverall: Duration = .seconds(3),
      maxReadBackPolls: Int = 3,
      maxConnectAttempts: Int = 5,
      connectResponseTimeout: Duration = .seconds(2)
    ) {
      self.settleWindow = settleWindow
      self.responseTimeout = responseTimeout
      self.drainIdle = drainIdle
      self.drainOverall = drainOverall
      self.maxReadBackPolls = maxReadBackPolls
      self.maxConnectAttempts = maxConnectAttempts
      self.connectResponseTimeout = connectResponseTimeout
    }
  }

  let config: BoseDeviceConfig
  let settings: Settings
  private let channel: any BmapChannel
  private let clock: any SessionClock

  private var parser = BmapStreamParser()
  private var drainTask: Task<Void, Never>?
  private var isClosed = false

  // MARK: Wire gate (single in-flight, FIFO)

  /// True from when a request claims the wire until it releases it. A second request
  /// never reaches the transport while one is in flight: with no sequence number there
  /// is no way to attribute interleaved answers, so requests are strictly serialised.
  private var isSending = false
  /// Requests waiting for the wire, resumed in arrival order.
  private var sendWaiters: [CheckedContinuation<Void, Never>] = []

  // MARK: In-flight mailbox (the current turn's frames)

  /// Which inbound frames belong to the request holding the wire. A frame that does not
  /// match is unsolicited and goes to `notifications`.
  private var currentMatcher: (@Sendable (BmapFrame) -> Bool)?
  /// Matching frames that arrived before the request asked for the next one.
  private var frameBuffer: [BmapFrame] = []
  private var frameWaiter: FrameWaiter?
  private var timeoutTask: Task<Void, Never>?
  private var nextWaiterToken: UInt64 = 0

  // MARK: Send pacing

  /// The earliest instant the next frame may be sent, moved forward by `settleWindow`
  /// after every send.
  private var nextSendAllowed: BmapInstant
  /// True while a send is parked waiting for the settle window. Exposed for tests, which
  /// have no other way to observe that the throttle is holding a send back.
  private(set) var isThrottlingSend = false

  // MARK: Notifications

  /// Unsolicited frames — anything not matching the request in flight, and everything
  /// that arrives with no request in flight. `nonisolated` so a consumer can start
  /// iterating without hopping onto the actor; the stream and its element are Sendable.
  public nonisolated let notifications: AsyncStream<BmapFrame>
  private nonisolated let notificationsContinuation: AsyncStream<BmapFrame>.Continuation

  private struct FrameWaiter {
    let token: UInt64
    /// Resolves with a frame, `nil` on timeout, or throws on cancel / close.
    let continuation: CheckedContinuation<BmapFrame?, Error>
  }

  private init(
    channel: any BmapChannel,
    config: BoseDeviceConfig,
    clock: any SessionClock,
    settings: Settings
  ) {
    self.channel = channel
    self.config = config
    self.clock = clock
    self.settings = settings
    self.nextSendAllowed = clock.now()
    let (stream, continuation) = AsyncStream<BmapFrame>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
    self.notifications = stream
    self.notificationsContinuation = continuation
  }

  /// Creates a session and starts its continuous drain of `inbound`.
  ///
  /// A factory rather than a plain init because the drain is a background task that
  /// captures the actor, which an actor's nonisolated init cannot start. The inbound
  /// stream buffers anything the device sends before the drain attaches, so a frame
  /// that races construction is not lost.
  public static func start(
    channel: any BmapChannel,
    inbound: AsyncStream<Data>,
    config: BoseDeviceConfig,
    clock: any SessionClock = SystemSessionClock(),
    settings: Settings = Settings()
  ) async -> BoseSession {
    let session = BoseSession(channel: channel, config: config, clock: clock, settings: settings)
    await session.beginDraining(inbound)
    return session
  }

  public static func start(
    opened: OpenedBmapChannel,
    config: BoseDeviceConfig,
    clock: any SessionClock = SystemSessionClock(),
    settings: Settings = Settings()
  ) async -> BoseSession {
    await start(
      channel: opened.channel,
      inbound: opened.inbound,
      config: config,
      clock: clock,
      settings: settings
    )
  }

  /// Starts the drain loop. Runs until close or the transport dropping its inbound
  /// stream; `weak self` breaks the self -> drainTask -> self retain cycle.
  private func beginDraining(_ inbound: AsyncStream<Data>) {
    drainTask = Task { [weak self] in
      for await chunk in inbound {
        await self?.ingest(chunk)
      }
      await self?.inboundEnded()
    }
  }

  // MARK: - Lifecycle

  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    tearDownWaiters()
    drainTask?.cancel()
    drainTask = nil
    await channel.close()
  }

  /// The transport's inbound stream ended without a local close, i.e. the device
  /// dropped the link. Same teardown as `close`, minus asking the channel to close what
  /// is already gone.
  private func inboundEnded() {
    guard !isClosed else { return }
    isClosed = true
    tearDownWaiters()
  }

  private func tearDownWaiters() {
    notificationsContinuation.finish()
    if let waiter = frameWaiter {
      frameWaiter = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      waiter.continuation.resume(throwing: BoseRequestError.sessionClosed)
    }
    // Waiting senders re-check `isClosed` when resumed and fail themselves.
    let waiters = sendWaiters
    sendWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  // MARK: - Draining

  private func ingest(_ chunk: Data) {
    let frames: [BmapFrame]
    do {
      frames = try parser.append(chunk)
    } catch {
      // The parser stashes frames recovered alongside a fault and hands them back on
      // the next append; flush them now with an empty append so a corrupt frame costs
      // only itself rather than delaying the good frames behind it.
      if let recovered = try? parser.append(Data()) {
        for frame in recovered { deliver(frame) }
      }
      return
    }
    for frame in frames { deliver(frame) }
  }

  private func deliver(_ frame: BmapFrame) {
    guard let matcher = currentMatcher, matcher(frame) else {
      notificationsContinuation.yield(frame)
      return
    }
    if let waiter = frameWaiter {
      frameWaiter = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      waiter.continuation.resume(returning: frame)
    } else {
      frameBuffer.append(frame)
    }
  }

  // MARK: - Wire gate

  /// Runs `body` as the sole holder of the wire. Later callers queue and are handed the
  /// wire in arrival order; the turn is always released, on success or throw, so a
  /// failure can never strand every request behind it.
  func withWireTurn<T>(_ body: () async throws -> T) async throws -> T {
    await claimSendTurn()
    do {
      // A request cancelled while it was queued for the wire must not send now that its
      // turn has come — that would spend a device round trip (and a settle window) on a
      // result nobody awaits, whose late answer could be mis-attributed to the next
      // request at the same address. Check once the turn is held, before body sends.
      try Task.checkCancellation()
      let result = try await body()
      finishWireTurn()
      return result
    } catch is CancellationError {
      finishWireTurn()
      throw BoseRequestError.cancelled
    } catch {
      finishWireTurn()
      throw error
    }
  }

  private func claimSendTurn() async {
    guard isSending else {
      isSending = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sendWaiters.append(continuation)
    }
    // Resumed only when the wire was handed over, so `isSending` is already true.
  }

  private func finishWireTurn() {
    currentMatcher = nil
    frameBuffer.removeAll()
    if let waiter = frameWaiter {
      frameWaiter = nil
      waiter.continuation.resume(throwing: BoseRequestError.cancelled)
    }
    timeoutTask?.cancel()
    timeoutTask = nil
    if sendWaiters.isEmpty {
      isSending = false
    } else {
      // Hand the wire straight to the next waiter; `isSending` stays true for it.
      sendWaiters.removeFirst().resume()
    }
  }

  /// Sets which inbound frames the current turn is listening for. Called at the start of
  /// each phase of an operation (a write-then-poll changes it between the write and the
  /// read-back).
  func listen(for matcher: @escaping @Sendable (BmapFrame) -> Bool) {
    currentMatcher = matcher
    // Anything buffered under a previous phase's matcher is no longer relevant.
    frameBuffer.removeAll()
  }

  // MARK: - Sending

  /// Sends a frame, first waiting out the settle window so consecutive sends keep the
  /// minimum interval apart on the injected clock.
  func throttledSend(_ frame: BmapFrame) async throws {
    if isClosed { throw BoseRequestError.sessionClosed }
    if clock.now() < nextSendAllowed {
      isThrottlingSend = true
      defer { isThrottlingSend = false }
      do {
        try await clock.sleep(until: nextSendAllowed)
      } catch {
        throw BoseRequestError.cancelled
      }
    }
    if isClosed { throw BoseRequestError.sessionClosed }
    do {
      try await channel.send(frame)
    } catch let failure as BmapChannelFailure {
      throw BoseRequestError.channel(failure)
    } catch {
      throw BoseRequestError.channel(.writeRejected)
    }
    nextSendAllowed = clock.now().advanced(by: settings.settleWindow)
  }

  // MARK: - Awaiting frames

  /// Awaits the next frame the current matcher accepts, or `nil` if `deadline` passes
  /// first. Throws `cancelled` if the caller's task is cancelled and `sessionClosed`
  /// if the session goes away.
  func nextFrame(before deadline: BmapInstant) async throws -> BmapFrame? {
    if isClosed { throw BoseRequestError.sessionClosed }
    if !frameBuffer.isEmpty { return frameBuffer.removeFirst() }

    let token = nextWaiterToken
    nextWaiterToken &+= 1
    let clock = self.clock

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BmapFrame?, Error>) in
        if isClosed {
          continuation.resume(throwing: BoseRequestError.sessionClosed)
          return
        }
        if Task.isCancelled {
          continuation.resume(throwing: BoseRequestError.cancelled)
          return
        }
        frameWaiter = FrameWaiter(token: token, continuation: continuation)
        // The timeout sleeps off-actor on the injected clock, then hops back to fire.
        // If a frame arrives first, `deliver` cancels this task; if cancelled here, the
        // swallowed sleep just proceeds to a no-op `fireTimeout`.
        // Task.init inherits this actor's isolation, so `fireTimeout` is a same-actor
        // call; `clock.sleep` is the one suspension point, during which the actor is free.
        timeoutTask = Task {
          try? await clock.sleep(until: deadline)
          self.fireTimeout(token: token)
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(token: token) }
    }
  }

  private func fireTimeout(token: UInt64) {
    guard let waiter = frameWaiter, waiter.token == token else { return }
    frameWaiter = nil
    timeoutTask = nil
    waiter.continuation.resume(returning: nil)
  }

  private func cancelWaiter(token: UInt64) {
    guard let waiter = frameWaiter, waiter.token == token else { return }
    frameWaiter = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    waiter.continuation.resume(throwing: BoseRequestError.cancelled)
  }

  /// The session's current instant. Internal so the operations extension (a separate
  /// file) can measure every deadline from the moment it is armed.
  func now() -> BmapInstant { clock.now() }

  // MARK: - Test visibility

  /// True while a request is parked waiting for a frame (buffer empty, no frame yet).
  /// Lets a test know the drain has consumed every delivered frame and is now idle,
  /// so it can advance the clock to fire a timeout deterministically.
  var isAwaitingFrame: Bool { frameWaiter != nil }

  /// How many requests are queued behind the wire holder — lets a test wait until a
  /// second request has actually parked in the queue before cancelling it.
  var queuedRequestCount: Int { sendWaiters.count }
}
