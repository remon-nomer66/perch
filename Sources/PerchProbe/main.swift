import Foundation
import IOBluetooth
import TandemCore
import TandemSession

// Reads a connected device's identity and capability inventory and prints it.
// Nothing is written to the device.

struct ProbeRequester: SessionRequesting {
  let channel: any TandemChannel
  let inbound: InboundQueue

  var timeout: TimeInterval = 8

  func request(
    _ build: @Sendable (UInt8) throws -> TandemFrame,
    matching: @Sendable @escaping (TandemFrame) -> Bool
  ) async throws -> TandemFrame {
    let sequence = await inbound.nextSequence()
    let frame = try build(sequence)
    try await channel.write(frame.encoded())
    return try await inbound.waitForFrame(matching: matching, channel: channel, timeout: timeout)
  }
}

/// The channel opened fine but no matching answer arrived in time. Kept distinct
/// from `ChannelFailure.openTimedOut`, which is about opening the channel itself —
/// reusing that here made an unanswered request look like a connection problem.
struct ResponseTimedOut: Error, CustomStringConvertible {
  let seconds: TimeInterval
  var description: String { "no matching response within \(seconds)s" }
}

actor InboundQueue {
  private var parser = FrameStreamParser()
  private let router = TandemRouter()
  private var frames: [TandemFrame] = []
  private var sequence: UInt8 = 0

  /// Upper bound on frames retained for matching. During capture, frames are printed
  /// as they arrive; keeping an unbounded backlog on top of that only grows memory
  /// over a long listen, so the oldest are dropped once this many are pending.
  private let maximumBufferedFrames = 512

  /// When set, every inbound chunk and decoded frame is printed with the elapsed
  /// time since capture began, so an unsolicited notification can be lined up against
  /// the physical gesture that produced it. Nothing device-identifying is printed —
  /// only protocol bytes.
  private var captureStart: Date?
  func beginCapture() { captureStart = Date() }

  func nextSequence() -> UInt8 {
    defer { sequence ^= 1 }
    return sequence
  }

  func consume(_ data: Data, channel: any TandemChannel) async {
    if let start = captureStart {
      let elapsed = Date().timeIntervalSince(start)
      let raw = data.map { String(format: "%02X", $0) }.joined(separator: " ")
      print(String(format: "[%7.3f] chunk %@", elapsed, raw))
      fflush(stdout)
    }
    let parsed = parser.append(data)
    let routed = router.route(parsed.frames)
    for ack in routed.acknowledgements {
      try? await channel.write(ack.encoded())
    }
    for event in routed.events {
      if case .data(let frame) = event {
        frames.append(frame)
        if frames.count > maximumBufferedFrames {
          frames.removeFirst(frames.count - maximumBufferedFrames)
        }
        if let start = captureStart {
          let elapsed = Date().timeIntervalSince(start)
          let payload = [UInt8](frame.payload).map { String(format: "%02X", $0) }
            .joined(separator: " ")
          print(String(format: "[%7.3f] frame dt=0x%02X  %@", elapsed, frame.dataType, payload))
          fflush(stdout)
        }
      }
    }
  }

  func waitForFrame(
    matching: @Sendable (TandemFrame) -> Bool,
    channel: any TandemChannel,
    timeout: TimeInterval = 8
  ) async throws -> TandemFrame {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let index = frames.firstIndex(where: matching) {
        return frames.remove(at: index)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ResponseTimedOut(seconds: timeout)
  }
}

let usageText = """
  usage: perch-probe capture [seconds]           passive frame dump (default 45s);
                                                 auto-selects the connected device
                                                 (its address is never printed)
         perch-probe <bluetooth-address>         identity + capability probe
         perch-probe <bluetooth-address> listen  fast wide status/parameter sweep
  """

func failUsage(_ message: String? = nil) -> Never {
  var text = usageText
  if let message { text = message + "\n" + text }
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(2)
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let isCapture = rawArgs.first == "capture"
let isListen = !isCapture && rawArgs.count > 1 && rawArgs[1] == "listen"

// Reject shapes that would otherwise be silently misread (an extra word used to be
// ignored, and a non-numeric duration used to fall back to the default).
if rawArgs.isEmpty { failUsage() }
if isCapture && rawArgs.count > 2 { failUsage() }
if !isCapture && rawArgs.count > 1 && !isListen {
  failUsage("unrecognized argument '\(rawArgs[1])'")
}

let captureSeconds: Double
if isCapture, rawArgs.count > 1 {
  // Guard against nan/infinity (which trap on Int conversion) and typos.
  guard let parsed = Double(rawArgs[1]), parsed.isFinite, (1.0...3600.0).contains(parsed) else {
    failUsage("capture duration must be a number of seconds in 1...3600, got '\(rawArgs[1])'")
  }
  captureSeconds = parsed
} else {
  captureSeconds = 45
}

/// The address of a connected, paired device that advertises Sony's control service.
/// Used only to open the channel; it is never printed, so it stays out of any log.
func connectedTandemAddress() -> String? {
  let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
  for device in paired where device.isConnected() {
    guard let reported = device.addressString else { continue }
    if TandemServiceGeneration.discover(address: reported) != nil { return reported }
  }
  return nil
}

let address: String?
if isCapture {
  address = connectedTandemAddress()
  if address == nil {
    print("no connected Sony control device found")
    exit(1)
  }
} else {
  address = rawArgs.first
}
guard let address else { failUsage() }

let opener = RFCOMMChannelOpener()
let opened: OpenedChannel
do {
  opened = try await opener.open(DeviceIdentity(address))
} catch {
  print("could not open a channel: \(error)")
  exit(1)
}
print("channel open, mtu \(opened.maximumTransmissionUnit)")
if let found = TandemServiceGeneration.discover(address: address) {
  print("sdp             \(found.generation.rawValue), channel \(found.channel)")
} else {
  print("sdp             no service record")
}

let queue = InboundQueue()
let reader = Task {
  for await chunk in opened.inbound {
    await queue.consume(chunk, channel: opened.channel)
  }
}

// Passive capture: reproduce the state the app leaves the device in (read-only
// handshake plus one feature read), then only listen. The question this answers is
// whether the headset, while a control channel is held open, reports its touch
// gestures (double-tap, swipe) as notification frames. If it does, they appear here
// with a timestamp and can be re-injected as macOS media keys; if nothing arrives,
// the gestures are being swallowed and re-injection is impossible.
if isCapture {
  let seconds = captureSeconds
  let requester = ProbeRequester(channel: opened.channel, inbound: queue)
  if let fingerprint = try? await DeviceVerification().readFingerprint(over: requester) {
    _ = await FeatureReader().read(
      declaring: fingerprint.table1Functions,
      dialect: fingerprint.dialect,
      over: requester
    )
  }
  print("--- CAPTURE: perform gestures now, \(Int(seconds))s window ---")
  fflush(stdout)
  await queue.beginCapture()
  try? await Task.sleep(for: .seconds(seconds))
  print("--- CAPTURE END ---")
  reader.cancel()
  await opened.channel.close()
  exit(0)
}

// Fast, listening-only wide sweep for locating a feature by diffing device states.
// The 0xE2/0xE3 and 0xE6/0xE7 pairs mirror TandemListeningModeProtocol's private
// get/return command bytes in TandemCore; 0xE0, 0xE4 and 0xEA are the neighboring
// even command bytes probed speculatively for capability/extended responses.
if isListen {
  func fastSweep(get: UInt8, expect: UInt8) async {
    var answered: [String] = []
    for inquiry in UInt8(0x00)...UInt8(0x1F) {
      var requester = ProbeRequester(channel: opened.channel, inbound: queue)
      requester.timeout = 0.8
      guard
        let frame = try? await requester.request(
          {
            try TandemFrame(
              dataType: TandemFrame.table1DataType,
              sequence: $0,
              payload: Data([get, inquiry])
            )
          },
          matching: { candidate in
            let bytes = [UInt8](candidate.payload)
            return bytes.count >= 2 && bytes[0] == expect && bytes[1] == inquiry
          }
        )
      else { continue }
      let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
      answered.append(String(format: "  0x%02X: %@", inquiry, hex))
    }
    print(answered.isEmpty ? "  (none)" : answered.joined(separator: "\n"))
    fflush(stdout)
  }
  print("--- wide status 0xE2->0xE3 ---")
  await fastSweep(get: 0xE2, expect: 0xE3)
  print("--- wide parameter 0xE6->0xE7 ---")
  await fastSweep(get: 0xE6, expect: 0xE7)
  // Look for a capability/label response for the listening family: any command that
  // answers may carry the room count or names, the way EQ's extended info carries band
  // frequencies. If nothing answers, the names are not on the device.
  print("--- capability probe 0xE0->0xE1 ---")
  await fastSweep(get: 0xE0, expect: 0xE1)
  print("--- extended probe 0xEA->0xEB ---")
  await fastSweep(get: 0xEA, expect: 0xEB)
  print("--- extended probe 0xE4->0xE5 ---")
  await fastSweep(get: 0xE4, expect: 0xE5)
  reader.cancel()
  await opened.channel.close()
  exit(0)
}

do {
  let fingerprint = try await DeviceVerification().readFingerprint(
    over: ProbeRequester(channel: opened.channel, inbound: queue)
  )

  print("model            \(fingerprint.modelName)")
  print("firmware         \(fingerprint.firmwareVersion)")
  print(String(format: "protocol         0x%08X", fingerprint.protocolIdentifier))
  print("protocol flags   \(fingerprint.protocolFirstFlag), \(fingerprint.protocolSecondFlag)")
  print("capability       code \(fingerprint.capabilityCode), identifier length \(fingerprint.capabilityIdentifierLength)")
  print("table 1          \(fingerprint.table1Functions.count) functions")
  for function in fingerprint.table1Functions {
    print(String(format: "  0x%02X v%d", function.code, function.version))
  }
  print("table 2          \(fingerprint.table2Functions.count) functions")
  for function in fingerprint.table2Functions {
    print(String(format: "  0x%02X v%d", function.code, function.version))
  }

  do {
    let profile = try TandemVerifiedDeviceRegistry.verifiedProfile(for: fingerprint)
    print("verified against \(profile.id)")
  } catch {
    print("not verified: \(error)")
  }

  let readings = await FeatureReader().read(
    declaring: fingerprint.table1Functions,
    dialect: fingerprint.dialect,
    over: ProbeRequester(channel: opened.channel, inbound: queue)
  )
  print("housing         \(fingerprint.housing)")
  print("battery single  \(readings.singleBattery.map(String.init) ?? "—")")
  print("battery left    \(readings.leftBattery.map(String.init) ?? "—")")
  print("battery right   \(readings.rightBattery.map(String.init) ?? "—")")
  print("battery case    \(readings.caseBattery.map(String.init) ?? "—")")
  print("codec           \(readings.codec?.description ?? "—")")
  if let noise = readings.noiseControl {
    print("noise control   inquiry 0x\(String(format: "%02X", noise.inquiry)), active \(noise.state.isActive), nc \(noise.state.isNoiseCancelling), mode \(noise.state.ambientMode), level \(noise.state.ambientLevel)")
  } else {
    print("noise control   —")
  }
  if let equalizer = readings.equalizer {
    print("equalizer       preset 0x\(String(format: "%02X", equalizer.selectedPreset ?? 0xFF)), steps \(equalizer.bandSteps)")
  } else {
    print("equalizer       —")
  }

  // Raw payloads for the features whose option lists differ between models.
  func dump(_ label: String, command: UInt8, inquiry: UInt8, expect: UInt8) async {
    guard
      let frame = try? await ProbeRequester(channel: opened.channel, inbound: queue).request(
        {
          try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: $0,
            payload: Data([command, inquiry])
          )
        },
        matching: { candidate in
          let bytes = [UInt8](candidate.payload)
          return bytes.count >= 2 && bytes[0] == expect && bytes[1] == inquiry
        }
      )
    else {
      print("\(label): no answer")
      return
    }
    let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
    print("\(label): \(hex)")
  }

  print("")
  print("--- listening mode (0xEB) ---")
  await dump("  capability", command: 0xE2, inquiry: 0x09, expect: 0xE3)
  await dump("  parameter ", command: 0xE6, inquiry: 0x09, expect: 0xE7)
  // Sweep the inquiry byte: which one a model answers to varies, and that is the
  // thing a universal implementation has to discover rather than assume.
  func sweepPair(_ label: String, get: UInt8, expect: UInt8, inquiries: [UInt8]) async {
    var answered: [String] = []
    for inquiry in inquiries {
      var requester = ProbeRequester(channel: opened.channel, inbound: queue)
      requester.timeout = 1.2
      guard
        let frame = try? await requester.request(
          {
            try TandemFrame(
              dataType: TandemFrame.table1DataType,
              sequence: $0,
              payload: Data([get, inquiry])
            )
          },
          matching: { candidate in
            let bytes = [UInt8](candidate.payload)
            return bytes.count >= 2 && bytes[0] == expect && bytes[1] == inquiry
          }
        )
      else { continue }
      let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
      answered.append(String(format: "    inquiry 0x%02X: %@", inquiry, hex))
    }
    print("\(label):")
    print(answered.isEmpty ? "    (none answered)" : answered.joined(separator: "\n"))
    fflush(stdout)
  }

  print("--- listening family sweep (status 0xE2->0xE3) ---")
  await sweepPair("  status", get: 0xE2, expect: 0xE3,
                  inquiries: Array(UInt8(0x00)...UInt8(0x0C)))
  print("--- listening family sweep (parameter 0xE6->0xE7) ---")
  await sweepPair("  parameter", get: 0xE6, expect: 0xE7,
                  inquiries: Array(UInt8(0x00)...UInt8(0x0C)))
  func sweep(_ label: String, get: UInt8, expect: UInt8, inquiries: [UInt8]) async {
    var answered: [String] = []
    for inquiry in inquiries {
      guard
        let frame = try? await ProbeRequester(channel: opened.channel, inbound: queue).request(
          {
            try TandemFrame(
              dataType: TandemFrame.table1DataType,
              sequence: $0,
              payload: Data([get, inquiry])
            )
          },
          matching: { candidate in
            let bytes = [UInt8](candidate.payload)
            return bytes.count >= 2 && bytes[0] == expect && bytes[1] == inquiry
          }
        )
      else { continue }
      let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
      answered.append(String(format: "    inquiry 0x%02X: %@", inquiry, hex))
    }
    print("\(label):")
    print(answered.isEmpty ? "    (no inquiry answered)" : answered.joined(separator: "\n"))
  }

  print("")
  print("--- NC/ASM capability sweep (get 0x60) ---")
  // The inquiry list mirrors TandemNoiseControlType's private function→inquiry
  // table in TandemCore (0x15-0x19 are the mode-select variants, 0x01/0x02 the
  // legacy on/off and single-mode forms). Kept in sync by hand since that table
  // is not public; the sweep exists to see which of them this device answers.
  await sweep("  capability", get: 0x60, expect: 0x61,
              inquiries: [0x01, 0x02, 0x15, 0x16, 0x17, 0x18, 0x19])
  print("--- Speak-to-Chat capability sweep (get 0xF0) ---")
  await sweep("  capability", get: 0xF0, expect: 0xF1,
              inquiries: [TandemSpeakToChatProtocol.inquiryType1,
                          TandemSpeakToChatProtocol.inquiryType2])
  print("--- General setting capability (per slot 0xD1-0xD4, ja display) ---")
  for slot: UInt8 in [0xD1, 0xD2, 0xD3, 0xD4] {
    guard
      let frame = try? await ProbeRequester(channel: opened.channel, inbound: queue).request(
        {
          try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: $0,
            payload: Data([0xD0, slot, 0x0B])
          )
        },
        matching: { candidate in
          let bytes = [UInt8](candidate.payload)
          return bytes.count >= 2 && bytes[0] == 0xD1 && bytes[1] == slot
        }
      )
    else {
      print(String(format: "  slot 0x%02X: no answer", slot))
      continue
    }
    let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
    if let capability = try? TandemGeneralSettingProtocol.parseCapabilityResponse(frame) {
      print(String(format: "  slot 0x%02X: %@ [%@] type=%@", slot, capability.label.title,
                   hex, String(describing: capability.type)))
    } else {
      print(String(format: "  slot 0x%02X: %@ (unparsed)", slot, hex))
    }
  }

  print("--- external sound (0x6D) ---")
  await dump("  status   ", command: 0x62, inquiry: 0x17, expect: 0x63)
  await dump("  parameter", command: 0x66, inquiry: 0x17, expect: 0x67)

  print("--- equalizer (0x57) ---")
  let requester = ProbeRequester(channel: opened.channel, inbound: queue)
  if let frame = try? await requester.request(
    { try TandemReadOnlyEqualizer.capabilityRequest(sequence: $0) },
    matching: { [UInt8]($0.payload).first == 0x51 }
  ) {
    let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
    print("  capability raw: \(hex)")
    if let capability = try? TandemReadOnlyEqualizer.parseCapabilityResponse(frame) {
      print("  band count    : \(capability.bandCount)")
      print("  presets       : \(capability.presets.count)")
      for preset in capability.presets {
        print(String(format: "    0x%02X  %@", preset.identifier, preset.name))
      }
    }
  } else {
    print("  no answer")
  }

  // Preset names came back empty in the capability. They may live here instead.
  await dump("  extended  ", command: 0x5A, inquiry: 0x04, expect: 0x5B)
  await dump("  status    ", command: 0x52, inquiry: 0x04, expect: 0x53)
  await dump("  parameter ", command: 0x56, inquiry: 0x04, expect: 0x57)

  // The display-language byte is the other candidate for the empty names.
  for language: UInt8 in [0x00, 0x01, 0x0B] {
    guard
      let frame = try? await ProbeRequester(channel: opened.channel, inbound: queue).request(
        {
          try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: $0,
            payload: Data([0x50, 0x04, language])
          )
        },
        matching: { [UInt8]($0.payload).first == 0x51 }
      )
    else {
      print(String(format: "  language 0x%02X: no answer", language))
      continue
    }
    let hex = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
    print(String(format: "  language 0x%02X: %@", language, hex))
  }
} catch {
  print("probe failed: \(error)")
  reader.cancel()
  await opened.channel.close()
  exit(1)
}

reader.cancel()
await opened.channel.close()
