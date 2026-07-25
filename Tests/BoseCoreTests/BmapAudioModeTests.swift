import Foundation
import Testing

@testable import BoseCore

/// Builds a 48-byte [31.6] ModeConfig STATUS payload the way the device lays it out.
private func modeConfigStatus(
  index: UInt8,
  name: String,
  isUserEditable: Bool,
  isConfigured: Bool,
  cnc: UInt8 = 0,
  spatial: UInt8 = 0,
  wind: UInt8 = 0,
  anc: UInt8 = 0
) throws -> BmapFrame {
  var bytes = [UInt8](repeating: 0, count: 48)
  bytes[0] = index
  bytes[3] = isUserEditable ? 0x01 : 0x00
  bytes[4] = isConfigured ? 0x01 : 0x00
  for (offset, byte) in Array(name.utf8).prefix(32).enumerated() {
    bytes[6 + offset] = byte
  }
  bytes[42] = cnc
  bytes[44] = spatial
  bytes[45] = wind
  bytes[47] = anc
  return try BmapFrame(fblock: 31, function: 6, op: .status, payload: Data(bytes))
}

@Test func modeConfigReadsConfiguredFlagFromStatusByteFour() throws {
  let configured = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 0, name: "Quiet", isUserEditable: false, isConfigured: true)
  )
  #expect(configured.isConfigured)
  #expect(configured.name == "Quiet")
  #expect(!configured.isUserEditable)

  let empty = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 7, name: "None", isUserEditable: true, isConfigured: false)
  )
  #expect(!empty.isConfigured)
}

/// The flag, not the name, decides. A localised placeholder must not become a mode, and a
/// slot the user named "None" must not vanish — the two cases the name check got wrong.
@Test func modeConfigIgnoresNameWhenJudgingConfigured() throws {
  let localisedPlaceholder = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 8, name: "なし", isUserEditable: true, isConfigured: false)
  )
  #expect(!localisedPlaceholder.isConfigured)

  let userNamedNone = try BmapAudioMode.parseConfig(
    modeConfigStatus(index: 5, name: "None", isUserEditable: true, isConfigured: true)
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
      isConfigured: true,
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
