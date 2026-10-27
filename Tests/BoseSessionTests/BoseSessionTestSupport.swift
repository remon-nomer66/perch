import BoseCore
import Foundation

@testable import BoseSession

// MARK: - Mock channel

/// A `BmapChannel` that records what the session sends and lets a test feed scripted
/// inbound bytes. Sends are actor-isolated (they mutate the log); delivery is
/// nonisolated because the continuation is `Sendable`, so a test can push frames
/// without hopping onto the actor.
///
/// `deliver([frames])` concatenates the frames into a single inbound chunk, which the
/// session's `BmapStreamParser` then splits — this makes multi-frame delivery arrive
/// in one `append`, so a drain sees the whole run at once and the test stays
/// deterministic.
actor MockBmapChannel: BmapChannel {
  nonisolated let inbound: AsyncStream<Data>
  nonisolated let continuation: AsyncStream<Data>.Continuation
  private var sent: [BmapFrame] = []
  private var sendFailure: BmapChannelFailure?

  init() {
    (inbound, continuation) = AsyncStream<Data>.makeStream()
  }

  /// Makes every subsequent `send` throw, so a test can exercise the transport-failure
  /// path (the frame is not recorded as sent).
  func failSends(with failure: BmapChannelFailure) {
    sendFailure = failure
  }

  func send(_ frame: BmapFrame) async throws {
    if let sendFailure { throw sendFailure }
    sent.append(frame)
  }

  func close() async {
    continuation.finish()
  }

  // MARK: Test inspection / scripting

  func sentFrames() -> [BmapFrame] { sent }

  func sends(at address: BmapFunctionAddress) -> Int {
    sent.filter { $0.address == address }.count
  }

  func sendCount() -> Int { sent.count }

  nonisolated func deliver(_ frame: BmapFrame) {
    continuation.yield(frame.encoded())
  }

  nonisolated func deliver(_ frames: [BmapFrame]) {
    var chunk = Data()
    for frame in frames { chunk.append(frame.encoded()) }
    continuation.yield(chunk)
  }

  nonisolated func finishInbound() {
    continuation.finish()
  }
}

// MARK: - Session construction

func makeSession(
  config: BoseDeviceConfig = .qcUltra2,
  clock: TestSessionClock,
  settings: BoseSession.Settings
) async -> (BoseSession, MockBmapChannel) {
  let mock = MockBmapChannel()
  let session = await BoseSession.start(
    channel: mock,
    inbound: mock.inbound,
    config: config,
    clock: clock,
    settings: settings
  )
  return (session, mock)
}

/// Settle window zeroed so most tests need no clock choreography for pacing; the send
/// rate and connect-resend tests set their own non-zero windows.
func instantSettings(
  responseTimeout: Duration = .seconds(60),
  drainIdle: Duration = .milliseconds(500),
  drainOverall: Duration = .seconds(30),
  maxReadBackPolls: Int = 3,
  maxConnectAttempts: Int = 5,
  connectResponseTimeout: Duration = .seconds(2)
) -> BoseSession.Settings {
  BoseSession.Settings(
    settleWindow: .zero,
    responseTimeout: responseTimeout,
    drainIdle: drainIdle,
    drainOverall: drainOverall,
    maxReadBackPolls: maxReadBackPolls,
    maxConnectAttempts: maxConnectAttempts,
    connectResponseTimeout: connectResponseTimeout
  )
}

// MARK: - Frame builders (synthetic; no device vocabulary baked in)

func makeStatus(_ address: BmapFunctionAddress, _ payload: [UInt8] = []) throws -> BmapFrame {
  try BmapFrame(fblock: address.fblock, function: address.function, op: .status, payload: Data(payload))
}

func makeResult(_ address: BmapFunctionAddress, _ payload: [UInt8] = []) throws -> BmapFrame {
  try BmapFrame(fblock: address.fblock, function: address.function, op: .result, payload: Data(payload))
}

func makeProcessing(_ address: BmapFunctionAddress) throws -> BmapFrame {
  try BmapFrame(fblock: address.fblock, function: address.function, op: .processing)
}

func makeError(_ address: BmapFunctionAddress, code: UInt8) throws -> BmapFrame {
  try BmapFrame(fblock: address.fblock, function: address.function, op: .error, payload: Data([code]))
}

// MARK: - Polling

/// Waits for a condition to hold, polling on real time. Used only to observe that the
/// session reached a state (a frame was sent, the drain went idle); the timing under
/// test is driven by the injected clock, not by this.
func eventually(
  within timeout: Duration = .seconds(5),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}
