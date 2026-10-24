import BoseCore
import BoseSession
import BoseTransport
import Foundation
import TandemSession

@testable import Perch

// Addresses here are synthetic: a documentation OUI (00:11:22) and invented low octets,
// never a real unit's address.

// MARK: - Audio output

/// The default audio output, set by the test. `current()` is all the controller reads.
final class ScriptedAudioOutput: AudioOutputObserving, @unchecked Sendable {
  let changes: AsyncStream<AudioOutput>
  private let continuation: AsyncStream<AudioOutput>.Continuation
  private let lock = NSLock()
  private var now: AudioOutput

  init(_ output: AudioOutput = .other) {
    now = output
    (changes, continuation) = AsyncStream<AudioOutput>.makeStream()
  }

  /// The Bluetooth output at `address`.
  convenience init(bluetooth address: String) {
    self.init(.identified(DeviceIdentity(address)))
  }

  /// Changes the output and publishes the change, as a switch in Sound settings would.
  func emit(_ output: AudioOutput) {
    lock.withLock { now = output }
    continuation.yield(output)
  }

  func start() {}
  func stop() {}
  func current() -> AudioOutput { lock.withLock { now } }
}

// MARK: - Devices

/// A scanned BMAP candidate. Disconnected and never accessed unless said otherwise — the
/// facts that rank neither above the other.
func candidate(
  _ address: String,
  connected: Bool = false,
  lastAccess: Date? = nil
) -> BmapDeviceCandidate {
  BmapDeviceCandidate(address: address, isConnected: connected, lastAccess: lastAccess)
}

/// How a scripted BMAP address behaves when opened.
enum ScriptedBmapBehaviour {
  /// The open itself fails.
  case refusesToOpen
  /// The channel opens, but every request on it fails: a link that says nothing.
  case opensSilently
  /// The channel opens and answers the device name and battery GETs.
  case readsBack
}

/// A `BmapDeviceAccess` with scripted candidates, recording every open it is asked for.
/// Candidates are listed in the order given, none of them connected, none with an access
/// date, so correlation falls back to the scan order unless a test says otherwise.
@MainActor
final class ScriptedBmapDevices: BmapDeviceAccess {
  var scanned: [BmapDeviceCandidate]
  var behaviours: [String: ScriptedBmapBehaviour]
  private(set) var opened: [String] = []
  /// How many SDP scans the controller has asked for.
  private(set) var scans = 0

  init(_ behaviours: KeyValuePairs<String, ScriptedBmapBehaviour>) {
    scanned = behaviours.map { candidate($0.key) }
    self.behaviours = Dictionary(uniqueKeysWithValues: behaviours.map { ($0.key, $0.value) })
  }

  func candidates() -> [BmapDeviceCandidate] {
    scans += 1
    return scanned
  }

  func config(forAddress address: String) -> (config: BoseDeviceConfig, productId: UInt16?) {
    (BoseCatalog.fallbackConfig, nil)
  }

  func open(address: String, timeout: Duration) async throws -> OpenedBmapChannel {
    opened.append(address)
    switch behaviours[address] ?? .refusesToOpen {
    case .refusesToOpen:
      throw BmapChannelOpenFailure.openTimedOut
    case .opensSilently:
      return AnsweringBmapChannel(answers: [:]).opened
    case .readsBack:
      return AnsweringBmapChannel(answers: AnsweringBmapChannel.readsBack).opened
    }
  }
}

/// A BMAP channel that answers the GETs it was given and refuses every other send, so a
/// test can stand up a device that reads back — or one that opens and says nothing —
/// with no radio. A refused send fails its request at once, so nothing waits out a
/// response timeout.
actor AnsweringBmapChannel: BmapChannel {
  /// A device name and a single battery component, the least that makes a link count as
  /// controllable and gives the readout a name and a charge to carry.
  static let readsBack: [BmapFunctionAddress: Data] = [
    .deviceName: Data([0x00] + Array("Model X".utf8)),
    .battery: Data([0x50, 0xff, 0xff, 0x00]),
  ]

  nonisolated let inbound: AsyncStream<Data>
  private nonisolated let continuation: AsyncStream<Data>.Continuation
  private let answers: [BmapFunctionAddress: Data]

  init(answers: [BmapFunctionAddress: Data]) {
    self.answers = answers
    (inbound, continuation) = AsyncStream<Data>.makeStream()
  }

  nonisolated var opened: OpenedBmapChannel {
    OpenedBmapChannel(channel: self, inbound: inbound)
  }

  func send(_ frame: BmapFrame) async throws {
    guard frame.op == .get, let payload = answers[frame.address] else {
      throw BmapChannelFailure.writeRejected
    }
    let reply = try BmapFrame(
      fblock: frame.fblock, function: frame.function, op: .status, payload: payload
    )
    continuation.yield(reply.encoded())
  }

  func close() async {
    continuation.finish()
  }
}

// MARK: - Assertions

extension BoseDeviceController {
  /// The invariant the shared readout must keep: it says `.ready` only while there is a
  /// live panel to drive. A `.ready` readout without one is the ghost device the notch
  /// and the settings window used to draw Sony controls under.
  var readoutAgreesWithPanel: Bool {
    readout?.status != .ready || panelModel != nil
  }
}
