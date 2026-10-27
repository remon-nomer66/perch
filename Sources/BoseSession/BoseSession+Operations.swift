import BoseCore
import Foundation

/// The BMAP operation kinds (frozen spec §5.1). Each claims the wire for its whole
/// span, so a write-then-poll's read-back cannot be interleaved with another request.
extension BoseSession {
  // MARK: - Connect

  /// Brings the link to a state where GETs are answered.
  ///
  /// A model that needs a connect-time init (QC35: it stays silent until it receives
  /// [0.1]) has that init resent until the device answers, capped by
  /// `maxConnectAttempts` — the device dropping the odd ping is expected, so one
  /// unanswered init is not a failure. A model that needs none (Ultra 2: GETs work
  /// immediately) returns at once. Any frame at the init address counts as "the device
  /// is up", including an ERROR: per the frozen spec an ERROR proves the link works.
  public func connect() async throws {
    let initFrame: BmapFrame?
    do {
      initFrame = try config.makeInitializeFrame()
    } catch {
      // A config that cannot even build its init frame is a programming error, not a
      // device state; surface it as a failed connect rather than crashing.
      throw BoseSessionError.connectFailed(attempts: 0)
    }
    guard let initFrame else { return }

    do {
      try await withWireTurn {
        self.listen { $0.address == initFrame.address }
        var attempt = 0
        while true {
          attempt += 1
          try await self.throttledSend(initFrame)
          let deadline = self.now().advanced(by: self.settings.connectResponseTimeout)
          if try await self.nextFrame(before: deadline) != nil {
            return
          }
          if attempt >= self.settings.maxConnectAttempts {
            throw BoseSessionError.connectFailed(attempts: attempt)
          }
        }
      }
    } catch let error as BoseRequestError {
      // Preserve the real cause instead of reporting a "resent to the cap" that did not
      // happen: a cancel or a transport failure on the first send is not the same as the
      // device staying silent through every retry.
      switch error {
      case .sessionClosed: throw BoseSessionError.sessionClosed
      case .cancelled: throw BoseSessionError.cancelled
      case .channel(let failure): throw BoseSessionError.channel(failure)
      default: throw BoseSessionError.connectFailed(attempts: settings.maxConnectAttempts)
      }
    }
  }

  // MARK: - Single response

  /// Sends one frame and resolves on the first STATUS or RESULT that matches. An ERROR
  /// is turned into a typed `BoseRequestError.device`; a PROCESSING is not terminal, so
  /// it is ignored and the response deadline is renewed to wait for what follows.
  public func request(
    _ frame: BmapFrame,
    matching: @escaping @Sendable (BmapFrame) -> Bool,
    responseTimeout: Duration? = nil
  ) async throws -> BmapFrame {
    let address = frame.address
    return try await withWireTurn {
      self.listen(for: Self.matcher(matching, orErrorAt: address))
      try await self.throttledSend(frame)
      return try await self.awaitTerminal(
        responseTimeout: responseTimeout ?? self.settings.responseTimeout
      )
    }
  }

  /// Convenience for the common case where the answer carries the same address as the
  /// request (a GET's STATUS, a SETGET's echo, an ERROR at the same function).
  public func request(
    _ frame: BmapFrame,
    responseTimeout: Duration? = nil
  ) async throws -> BmapFrame {
    let address = frame.address
    return try await request(
      frame,
      matching: { $0.address == address },
      responseTimeout: responseTimeout
    )
  }

  // MARK: - Multi response (drain)

  /// Sends one frame and accumulates every related STATUS the device streams back
  /// (a GetAll answers with a run of them). Ends when the stream goes idle for
  /// `drainIdle`, or the overall deadline passes, whichever comes first. A first-answer
  /// timeout with nothing collected is `noResponse`; an ERROR anywhere aborts with a
  /// typed error; a PROCESSING is skipped without ending the drain.
  public func requestMany(
    _ frame: BmapFrame,
    matching: @escaping @Sendable (BmapFrame) -> Bool,
    firstResponseTimeout: Duration? = nil,
    idle: Duration? = nil,
    overall: Duration? = nil
  ) async throws -> [BmapFrame] {
    let address = frame.address
    return try await withWireTurn {
      self.listen(for: Self.matcher(matching, orErrorAt: address))
      try await self.throttledSend(frame)
      return try await self.drain(
        firstResponseTimeout: firstResponseTimeout ?? self.settings.responseTimeout,
        idle: idle ?? self.settings.drainIdle,
        overall: overall ?? self.settings.drainOverall
      )
    }
  }

  /// Convenience matching by the request's own address — the common case, and the safe
  /// default (it takes STATUS runs and ERRORs at that address, never dropping the ERROR
  /// the way a hand-written `{ $0.op == .status }` would).
  public func requestMany(
    _ frame: BmapFrame,
    firstResponseTimeout: Duration? = nil,
    idle: Duration? = nil,
    overall: Duration? = nil
  ) async throws -> [BmapFrame] {
    let address = frame.address
    return try await requestMany(
      frame,
      matching: { $0.address == address },
      firstResponseTimeout: firstResponseTimeout,
      idle: idle,
      overall: overall
    )
  }

  // MARK: - Write then poll

  /// Writes a value (a SETGET), then reads it back (a GET) until the device reports the
  /// value that was written or the read-backs run out. This is the only real check on an
  /// unverified device: the write's own echo can lie, so what stuck is confirmed by a
  /// separate read. The settle window between the write and each read-back is enforced
  /// by the shared send throttle. Failing to confirm is `notApplied`, carrying the last
  /// read-back so the caller can see what the device actually holds.
  ///
  /// - Parameters:
  ///   - isApplied: judges a read-back frame — true means the write took.
  @discardableResult
  public func writeThenPoll(
    write: BmapFrame,
    readBack: BmapFrame,
    writeMatching: @escaping @Sendable (BmapFrame) -> Bool,
    readMatching: @escaping @Sendable (BmapFrame) -> Bool,
    isApplied: @escaping @Sendable (BmapFrame) -> Bool,
    maxPolls: Int? = nil,
    responseTimeout: Duration? = nil
  ) async throws -> BmapFrame {
    let timeout = responseTimeout ?? settings.responseTimeout
    let polls = maxPolls ?? settings.maxReadBackPolls
    let writeAddress = write.address
    let readAddress = readBack.address
    return try await withWireTurn {
      // Phase 1: the write. Its terminal answer is consumed (and an ERROR surfaces here).
      self.listen(for: Self.matcher(writeMatching, orErrorAt: writeAddress))
      try await self.throttledSend(write)
      let writeResponse = try await self.awaitTerminal(responseTimeout: timeout)

      // Phase 2: read the value back until it matches or the polls run out.
      self.listen(for: Self.matcher(readMatching, orErrorAt: readAddress))
      var last = writeResponse
      for _ in 0..<max(polls, 1) {
        try await self.throttledSend(readBack)
        let readResponse = try await self.awaitTerminal(responseTimeout: timeout)
        last = readResponse
        if isApplied(readResponse) { return readResponse }
      }
      throw BoseRequestError.notApplied(last)
    }
  }

  /// Convenience matching write and read-back by their own addresses.
  @discardableResult
  public func writeThenPoll(
    write: BmapFrame,
    readBack: BmapFrame,
    isApplied: @escaping @Sendable (BmapFrame) -> Bool,
    maxPolls: Int? = nil,
    responseTimeout: Duration? = nil
  ) async throws -> BmapFrame {
    let writeAddress = write.address
    let readAddress = readBack.address
    return try await writeThenPoll(
      write: write,
      readBack: readBack,
      writeMatching: { $0.address == writeAddress },
      readMatching: { $0.address == readAddress },
      isApplied: isApplied,
      maxPolls: maxPolls,
      responseTimeout: responseTimeout
    )
  }

  // MARK: - Matcher helpers

  /// Widens a caller's matcher so an `ERROR` at the request's own address is always
  /// delivered, whatever the matcher says. Without this a matcher like `{ $0.op == .status }`
  /// silently routes the device's ERROR to the notification stream, and the drain /
  /// answer loop — which is what turns an ERROR into a typed failure — never sees it. The
  /// contract is "an ERROR for this request aborts it"; this makes the low-level matcher
  /// honour that no matter how narrow the caller's predicate is.
  static func matcher(
    _ matching: @escaping @Sendable (BmapFrame) -> Bool,
    orErrorAt address: BmapFunctionAddress
  ) -> @Sendable (BmapFrame) -> Bool {
    { matching($0) || ($0.op == .error && $0.address == address) }
  }

  // MARK: - Shared answer handling

  /// Waits for a terminal answer, renewing the deadline on each PROCESSING.
  private func awaitTerminal(responseTimeout: Duration) async throws -> BmapFrame {
    guard let frame = try await awaitTerminalOrTimeout(responseTimeout: responseTimeout) else {
      throw BoseRequestError.timedOut
    }
    return frame
  }

  /// The core answer loop, returning `nil` on timeout so callers that resend (connect)
  /// can distinguish silence from a device error.
  private func awaitTerminalOrTimeout(responseTimeout: Duration) async throws -> BmapFrame? {
    var deadline = now().advanced(by: responseTimeout)
    while true {
      guard let frame = try await nextFrame(before: deadline) else { return nil }
      switch frame.op {
      case .error:
        throw Self.deviceError(from: frame)
      case .processing:
        // The device said it is still working, so keep waiting and renew the deadline.
        deadline = now().advanced(by: responseTimeout)
      default:
        // STATUS / RESULT (or any non-error, non-processing answer) is terminal.
        return frame
      }
    }
  }

  private func drain(
    firstResponseTimeout: Duration,
    idle: Duration,
    overall: Duration
  ) async throws -> [BmapFrame] {
    var collected: [BmapFrame] = []
    let overallDeadline = now().advanced(by: overall)

    // First answer: silence here means the device never engaged.
    let firstDeadline = min(now().advanced(by: firstResponseTimeout), overallDeadline)
    guard let first = try await nextFrame(before: firstDeadline) else {
      throw BoseRequestError.noResponse
    }
    try collect(first, into: &collected)

    // Subsequent answers: keep taking them until an idle gap or the overall deadline.
    while now() < overallDeadline {
      let deadline = min(now().advanced(by: idle), overallDeadline)
      guard let frame = try await nextFrame(before: deadline) else { break }
      try collect(frame, into: &collected)
    }
    return collected
  }

  private func collect(_ frame: BmapFrame, into collected: inout [BmapFrame]) throws {
    switch frame.op {
    case .error:
      throw Self.deviceError(from: frame)
    case .processing:
      break  // not a value; keep draining
    default:
      collected.append(frame)
    }
  }

  private static func deviceError(from frame: BmapFrame) -> BoseRequestError {
    if let code = frame.errorCode { return .device(code) }
    return .deviceUnknown(rawCode: frame.rawErrorCode)
  }
}
