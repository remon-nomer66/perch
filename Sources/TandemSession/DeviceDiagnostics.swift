import Foundation
import TandemCore

/// Gathers the raw read-only exchanges a support report includes.
///
/// Only capability, parameter, and extended-info reads are taken, and only for functions
/// the device declared — the same capability-driven rule the rest of the app follows, so
/// nothing unsupported is ever sent. Most queries mirror what `FeatureReader` already
/// runs; the system and playback sweeps go further, asking about declared functions the
/// app itself does not use yet. A device that will not answer one simply lets the
/// request time out and that capture is skipped. The bytes returned are the device's
/// own declared parameters, which carry no address or individual identifier.
public struct DeviceDiagnostics: Sendable {
  public init() {}

  public func rawCaptures(
    declaring functions: [TandemSupportFunction],
    over requests: SessionRequesting
  ) async -> [TandemRawCapture] {
    let declared = Set(functions.map(\.code))
    var captures: [TandemRawCapture] = []

    // Equaliser: capability carries band count and presets, extended the band
    // frequencies, parameter the current selection and levels.
    if declared.contains(0x57) {
      await add(&captures, "eq.capability", [0x50, 0x04, 0x0B], expect: 0x51, inquiry: 0x04, over: requests)
      await add(&captures, "eq.parameter", [0x56, 0x04], expect: 0x57, inquiry: 0x04, over: requests)
      await add(&captures, "eq.extended", [0x5A, 0x04], expect: 0x5B, inquiry: 0x04, over: requests)
    }

    // Noise control: capability lists the ambient modes and their level ranges.
    if let inquiry = TandemNoiseControlType.inquiry(forDeclared: declared) {
      await add(&captures, "nc.capability", [0x60, inquiry], expect: 0x61, inquiry: inquiry, over: requests)
      await add(&captures, "nc.parameter", [0x66, inquiry], expect: 0x67, inquiry: inquiry, over: requests)
    }

    // Listening modes: the current parameter of each declared background-music/cinema
    // feature.
    for feature in TandemListeningCatalog.features(forDeclared: declared) {
      let inquiry = feature.inquiry
      await add(
        &captures, "listening.parameter.\(Self.hex(inquiry))",
        [0xE6, inquiry], expect: 0xE7, inquiry: inquiry, over: requests
      )
    }

    // Speak-to-chat: capability carries the auto-off seconds; parameter and extended the
    // current on/off, sensitivity, and timeout.
    if let inquiry = TandemSpeakToChatProtocol.inquiry(forDeclared: declared) {
      await add(&captures, "s2c.capability", [0xF0, inquiry], expect: 0xF1, inquiry: inquiry, over: requests)
      await add(&captures, "s2c.parameter", [0xF6, inquiry], expect: 0xF7, inquiry: inquiry, over: requests)
      await add(&captures, "s2c.extended", [0xFA, inquiry], expect: 0xFB, inquiry: inquiry, over: requests)
    }

    // General settings: each declared slot's capability carries its label and, for a
    // list setting, its choices — the surest way to see which slot is sidetone.
    for slot in [0xD1, 0xD2, 0xD3, 0xD4] as [UInt8] where declared.contains(slot) {
      await add(
        &captures, "general.\(Self.hex(slot)).capability",
        [0xD0, slot, 0x0B], expect: 0xD1, inquiry: slot, over: requests
      )
    }

    // System family (0xF0 reads): the inquiry is the function code's offset from the
    // family base — speak-to-chat showed the rule (0xF2 → 0x02, 0xFC → 0x0C). Every
    // declared code is read the same way; 0xF3 is the touch panel's assignable-setting
    // table, the capability that names its keys, presets, and actions. The
    // speak-to-chat codes are left out because their conversation is captured above.
    let speakToChat: Set<UInt8> = [
      TandemSpeakToChatProtocol.functionCodeType1,
      TandemSpeakToChatProtocol.functionCodeType2,
    ]
    for code in declared.sorted() where code >= 0xF0 && !speakToChat.contains(code) {
      let inquiry = code - 0xF0
      await add(
        &captures, "system.\(Self.hex(code)).capability",
        [0xF0, inquiry], expect: 0xF1, inquiry: inquiry, over: requests
      )
      await add(
        &captures, "system.\(Self.hex(code)).parameter",
        [0xF6, inquiry], expect: 0xF7, inquiry: inquiry, over: requests
      )
    }

    // Playback controller (0xA0 reads), by the same offset rule: what the device says
    // it can do with media transport, and how its function change is set.
    for code in declared.sorted() where (0xA1...0xA4).contains(code) {
      let inquiry = code - 0xA0
      await add(
        &captures, "playback.\(Self.hex(code)).capability",
        [0xA0, inquiry], expect: 0xA1, inquiry: inquiry, over: requests
      )
      await add(
        &captures, "playback.\(Self.hex(code)).parameter",
        [0xA6, inquiry], expect: 0xA7, inquiry: inquiry, over: requests
      )
    }

    return captures
  }

  private func add(
    _ captures: inout [TandemRawCapture],
    _ label: String,
    _ requestPayload: [UInt8],
    expect command: UInt8,
    inquiry: UInt8,
    over requests: SessionRequesting
  ) async {
    // A probe, not a request: the sweep asks about functions the device may not
    // implement, so a no-answer must skip this capture without tearing down the
    // session (which is exactly what a plain `request` timeout would do).
    guard
      let frame = try? await requests.probe(
        {
          try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: $0,
            payload: Data(requestPayload)
          )
        },
        matching: { candidate in
          let bytes = [UInt8](candidate.payload)
          return bytes.count >= 2 && bytes[0] == command && bytes[1] == inquiry
        }
      )
    else { return }
    captures.append(
      TandemRawCapture(label: label, request: requestPayload, response: [UInt8](frame.payload))
    )
  }

  private static func hex(_ value: UInt8) -> String { String(format: "%02X", value) }
}
