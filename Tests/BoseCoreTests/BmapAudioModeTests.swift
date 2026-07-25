import Foundation
import Testing

@testable import BoseCore

/// Builds a 48-byte [31.6] ModeConfig STATUS payload the way the device lays it out.
private func modeConfigStatus(
  index: UInt8,
  name: String,
  isUserEditable: Bool,
  prompt: UInt8 = 0,
  configuredFlag: UInt8 = 0,
  cnc: UInt8 = 0,
  spatial: UInt8 = 0,
  wind: UInt8 = 0,
  anc: UInt8 = 0
) throws -> BmapFrame {
  var bytes = [UInt8](repeating: 0, count: 48)
  bytes[0] = index
  bytes[2] = prompt
  bytes[3] = isUserEditable ? 0x01 : 0x00
  bytes[4] = configuredFlag
  for (offset, byte) in Array(name.utf8).prefix(32).enumerated() {
    bytes[6 + offset] = byte
  }
  bytes[42] = cnc
  bytes[44] = spatial
  bytes[45] = wind
  bytes[47] = anc
  return try BmapFrame(fblock: 31, function: 6, op: .status, payload: Data(bytes))
}

/// Bytes taken verbatim from a QC Ultra Earbuds capture (firmware 4.9.32). The device
/// reports 0 at STATUS[4] for *every* slot, so reading the reference's nominal
/// isConfigured flag alone leaves the mode list empty on real hardware; the voice-prompt
/// id at STATUS[2] is what separates the configured presets from the empty slots.
private let capturedSlots: [(index: UInt8, name: String, prompt: UInt8, editable: Bool, configured: Bool)] = [
  (0, "Quiet", 0x01, false, true),
  (1, "Aware", 0x02, false, true),
  (2, "Immersion", 0x22, false, true),
  (3, "None", 0x00, true, false),
  (4, "None", 0x00, true, false),
  (5, "None", 0x00, true, false),
  (6, "None", 0x00, true, false),
]

@Test func modeConfigMatchesTheCapturedEarbudsSlots() throws {
  for slot in capturedSlots {
    let parsed = try BmapAudioMode.parseConfig(
      modeConfigStatus(
        index: slot.index,
        name: slot.name,
        isUserEditable: slot.editable,
        prompt: slot.prompt,
        configuredFlag: 0  // as the hardware reports it, for every slot
      )
    )
    #expect(parsed.index == Int(slot.index))
    #expect(parsed.name == slot.name)
    #expect(parsed.isUserEditable == slot.editable)
    #expect(parsed.isConfigured == slot.configured)
  }
}

/// The reference's flag still counts when a device does set it — the prompt is an
/// additional signal, not a replacement.
@Test func modeConfigHonoursTheNominalConfiguredFlag() throws {
  let parsed = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 4, name: "Home", isUserEditable: true, prompt: 0, configuredFlag: 0x01)
  )
  #expect(parsed.isConfigured)
}

/// The payload, not the name, decides. A localised placeholder must not become a mode, and
/// a slot the user named "None" must not vanish — the two cases the name check got wrong.
@Test func modeConfigIgnoresNameWhenJudgingConfigured() throws {
  let localisedPlaceholder = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 8, name: "なし", isUserEditable: true, prompt: 0)
  )
  #expect(!localisedPlaceholder.isConfigured)

  let userNamedNone = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 5, name: "None", isUserEditable: true, prompt: 0x07)
  )
  #expect(userNamedNone.isConfigured)
  #expect(userNamedNone.name == "None")
}

@Test func modeConfigParsesNoiseControlPreset() throws {
  let config = try BmapAudioMode.parseConfig(
    modeConfigStatus(
      index: 2,
      name: "Immersion",
      isUserEditable: false,
      prompt: 0x22,
      cnc: 3,
      spatial: 2,
      wind: 1,
      anc: 1
    )
  )
  #expect(config.noiseControl == BmapNoiseControlSetting(
    cnc: 3, spatial: .head, windBlock: true, ancEnabled: true
  ))
}

// MARK: - Slot ranges

@Test func modeSlotsComeFromTheDeclaredRanges() {
  // Ultra 2: presets 0..<4 plus editable 4..<11.
  #expect(BoseDeviceConfig.qcUltra2.modeSlots == Array(0...10))
  #expect(BoseDeviceConfig.qcUltra2Earbuds.modeSlots == Array(0...10))
  // QC35 has no block 31 at all, so there is nothing to walk.
  #expect(BoseDeviceConfig.qc35.modeSlots.isEmpty)
}
