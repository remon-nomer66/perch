import Foundation
import TandemCore
import Testing

@testable import TandemSession

// Doubles shared by the session robustness tests. Everything here is synthetic: the
// payload bytes are the protocol's own command and inquiry codes, the fingerprint
// matches no real model, and the verifiers are stubs, so no device is imitated.

/// One end of a channel the test controls: answers table-1 requests from a script
/// keyed on the first two payload bytes, records every payload written, and can stall
/// its writes or drop the channel the way a headset does.
actor LinkDouble: TandemChannel {
  private let inbound: AsyncStream<Data>.Continuation
  private var decoder = TandemStreamDecoder()
  private var script: [[UInt8]: [UInt8]]
  private var payloads: [[UInt8]] = []
  private var stallsWrites = false
  private var stallsAcknowledgements = false
  private(set) var isClosed = false

  init(inbound: AsyncStream<Data>.Continuation, script: [[UInt8]: [UInt8]]) {
    self.inbound = inbound
    self.script = script
  }

  func write(_ data: Data) async throws {
    let frames = (try? decoder.append(data)) ?? []
    let isAcknowledgement = frames.contains { $0.dataType == TandemFrame.ackDataType }
    if stallsWrites || (isAcknowledgement && stallsAcknowledgements) {
      // Held the way `writeSync` is while the remote withholds flow-control credit,
      // and deaf to cancellation like the transport's write queue.
      try? await Task.sleep(for: .seconds(3600))
      return
    }
    for frame in frames where frame.dataType == TandemFrame.table1DataType {
      let bytes = [UInt8](frame.payload)
      payloads.append(bytes)
      if let reply = script[Array(bytes.prefix(2))] {
        try send(reply)
      }
    }
  }

  func close() async {
    isClosed = true
    inbound.finish()
  }

  /// Ends the channel from the device's side.
  func drop() {
    inbound.finish()
  }

  func stallWrites() { stallsWrites = true }
  func stallAcknowledgements() { stallsAcknowledgements = true }
  func answer(_ prefix: [UInt8], with reply: [UInt8]?) { script[prefix] = reply }

  func writes(withPrefix prefix: [UInt8]) -> Int {
    payloads.filter { Array($0.prefix(prefix.count)) == prefix }.count
  }

  /// Pushes a frame the device sends on its own: a reply, or an unsolicited notice.
  func send(_ payload: [UInt8]) throws {
    let frame = try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: 0,
      payload: Data(payload)
    )
    inbound.yield(frame.encoded())
  }
}

/// Hands out a fresh `LinkDouble` on every open, as reconnecting to a real device
/// yields a new channel, and keeps them so a test can reach the one in use.
final class LinkOpener: TandemChannelOpening, @unchecked Sendable {
  private let lock = NSLock()
  private let script: [[UInt8]: [UInt8]]
  private var opened: [LinkDouble] = []

  init(script: [[UInt8]: [UInt8]] = [:]) {
    self.script = script
  }

  var links: [LinkDouble] { lock.withLock { opened } }
  var latest: LinkDouble? { links.last }

  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    let link = LinkDouble(inbound: continuation, script: script)
    lock.withLock { opened.append(link) }
    return OpenedChannel(channel: link, inbound: stream, maximumTransmissionUnit: 512)
  }
}

struct FixedOutcomeVerifier: DeviceVerifying {
  let outcome: VerificationOutcome

  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    outcome
  }
}

/// A verified outcome for a synthetic device declaring `codes`.
func verifiedOutcome(declaring codes: [UInt8]) throws -> VerificationOutcome {
  let profile = try #require(TandemVerifiedDeviceRegistry.profiles.first)
  return .verified(profile, syntheticDevice(declaring: codes))
}

func syntheticDevice(declaring codes: [UInt8]) -> TandemDeviceFingerprint {
  TandemDeviceFingerprint(
    protocolIdentifier: 0x0102_0304,
    protocolFirstFlag: 0,
    protocolSecondFlag: 0,
    capabilityCode: 6,
    capabilityIdentifierLength: 17,
    modelName: "TEST-DEVICE",
    firmwareVersion: "1.0.0",
    table1Functions: codes.map { TandemSupportFunction(code: $0, version: 1) },
    table2Functions: [],
    dialect: .current
  )
}

/// Polls `condition` until it holds or `timeout` passes.
func waitFor(
  within timeout: Duration = .seconds(10),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

let linkTarget = DeviceIdentity("test-target")
/// The single-battery query and its answer: half charged.
let singleBatteryQuery: [UInt8] = [0x22, TandemBatteryQuery.single.rawValue]
let singleBatteryAnswer: [UInt8] = [0x23, TandemBatteryQuery.single.rawValue, 50, 0]
