import Foundation

/// One audio mode as the device reports it in a [31.6] ModeConfig STATUS.
///
/// A mode bundles a noise-control preset: its CNC level, spatial mode, wind block, and
/// ANC. On Ultra 2 this is also how the *current* noise-control state is read, because
/// the live [31.10] block answers a GET with `functionNotSupported` (verified on
/// hardware) — the app reads the active mode's config instead.
public struct BmapModeConfig: Equatable, Sendable {
  public let index: Int
  /// The device's own UTF-8 name (STATUS bytes 6...37), never coined here.
  public let name: String
  /// STATUS[3] bit 0: the user may edit this slot (the preset slots are not editable).
  public let isUserEditable: Bool
  /// Whether the slot holds a real, selectable mode. Read from the payload rather than
  /// inferred from the name: a placeholder name is localised on non-English firmware, and
  /// a user may legitimately name a slot "None". See `parseConfig` for which bytes decide
  /// it and why the reference's nominal flag alone does not.
  public let isConfigured: Bool
  /// The noise-control preset this mode carries. STATUS[42]=cnc, [44]=spatial, [45]=wind,
  /// [47]=anc (frozen spec / bose-bmap-reference §3).
  public let cnc: Int
  public let spatial: BmapNoiseControlSetting.Spatial
  public let windBlock: Bool
  public let ancEnabled: Bool

  public init(
    index: Int,
    name: String,
    isUserEditable: Bool,
    isConfigured: Bool,
    cnc: Int,
    spatial: BmapNoiseControlSetting.Spatial,
    windBlock: Bool,
    ancEnabled: Bool
  ) {
    self.index = index
    self.name = name
    self.isUserEditable = isUserEditable
    self.isConfigured = isConfigured
    self.cnc = cnc
    self.spatial = spatial
    self.windBlock = windBlock
    self.ancEnabled = ancEnabled
  }

  /// The noise-control state this mode represents, used to seed the live controls since
  /// [31.10] cannot be read back.
  public var noiseControl: BmapNoiseControlSetting {
    BmapNoiseControlSetting(cnc: cnc, spatial: spatial, windBlock: windBlock, ancEnabled: ancEnabled)
  }
}

/// Audio-modes protocol (block 31): the current mode [31.3], per-mode config [31.6], and
/// mode switching [31.3]. On Ultra 2 the modes are Quiet / Aware / Immersion / Cinema plus
/// user slots; Immersion and Cinema are the spatial-audio modes.
public enum BmapAudioMode {
  /// [31.3] — reads the current mode index and, as a START, switches modes.
  public static let currentAddress = BmapFunctionAddress(
    fblock: BmapFunctionBlock.audioModes, function: 3
  )
  /// [31.6] — per-mode configuration (its STATUS carries the noise-control preset).
  public static let configAddress = BmapFunctionAddress.modeConfig

  private static let statusLength = 48
  /// STATUS[1-2]: the mode's voice-prompt id. Non-zero exactly on the configured slots in
  /// the hardware capture below, which is what makes it usable as a configured marker.
  private static let promptOffset = 2
  /// STATUS[4]: the reference's nominal isConfigured flag.
  private static let configuredOffset = 4
  private static let nameRange = 6..<38
  private static let cncOffset = 42
  private static let spatialOffset = 44
  private static let windOffset = 45
  private static let ancOffset = 47

  // MARK: Current mode

  /// GET [31.3] — asks which mode is active.
  public static func currentModeRequest() throws -> BmapFrame {
    try BmapFrame(fblock: currentAddress.fblock, function: currentAddress.function, op: .get)
  }

  /// The active mode index from a [31.3] reply (its first payload byte).
  public static func parseCurrentMode(_ frame: BmapFrame) throws -> Int {
    guard frame.address == currentAddress else {
      throw BmapAudioModeError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    guard let index = frame.payload.first else {
      throw BmapAudioModeError.emptyPayload
    }
    return Int(index)
  }

  /// START [31.3] `[modeIndex, voicePrompt]` — switches to `index`. The reference marks
  /// this verified; `voicePrompt` false keeps the change silent (no spoken confirmation).
  public static func selectModeRequest(index: Int, voicePrompt: Bool = false) throws -> BmapFrame {
    guard (0...Int(UInt8.max)).contains(index) else {
      throw BmapAudioModeError.indexOutOfRange(index)
    }
    return try BmapFrame(
      fblock: currentAddress.fblock,
      function: currentAddress.function,
      op: .start,
      payload: Data([UInt8(index), voicePrompt ? 1 : 0])
    )
  }

  // MARK: Mode config

  /// GET [31.6] `[modeIndex]` — a bare GET returns `invalidData`; the index is required.
  public static func configRequest(index: Int) throws -> BmapFrame {
    guard (0...Int(UInt8.max)).contains(index) else {
      throw BmapAudioModeError.indexOutOfRange(index)
    }
    return try BmapFrame(
      fblock: configAddress.fblock,
      function: configAddress.function,
      op: .get,
      payload: Data([UInt8(index)])
    )
  }

  /// Parses a 48-byte [31.6] ModeConfig STATUS.
  ///
  /// A slot counts as configured when either the nominal flag at STATUS[4] or the voice
  /// prompt id at STATUS[2] is non-zero. The prompt is load-bearing, not a belt-and-braces
  /// extra: a QC Ultra Earbuds capture (firmware 4.9.32) reports **0 at [4] for every
  /// slot** — the configured Quiet / Aware / Immersion presets included — so reading the
  /// documented flag alone empties the mode list on real hardware. The prompt separates
  /// them cleanly on that same capture:
  ///
  ///     idx name        [2]  [3]  [4]
  ///     0   Quiet       01   00   00    configured preset
  ///     1   Aware       02   00   00    configured preset
  ///     2   Immersion   22   00   00    configured preset
  ///     3…6 None        00   01   00    empty, user-editable
  ///
  /// Judging by the name instead — empty, or the English literal "None" — is what this
  /// replaces: the placeholder is localised on non-English firmware, where every empty
  /// slot would then become a mode, and a slot a user names "None" disappears.
  ///
  /// Unverified: a *user-created* mode whose voice prompt is 0. The captured device had no
  /// custom mode to check, and such a slot would be missed here. Worth re-capturing once
  /// one exists.
  public static func parseConfig(_ frame: BmapFrame) throws -> BmapModeConfig {
    guard frame.address == configAddress else {
      throw BmapAudioModeError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= statusLength else {
      throw BmapAudioModeError.truncated(expected: statusLength, actual: bytes.count)
    }
    let nameBytes = bytes[nameRange].prefix { $0 != 0 }
    let name = String(decoding: nameBytes, as: UTF8.self)
    let spatial = BmapNoiseControlSetting.Spatial(rawValue: bytes[spatialOffset]) ?? .off
    return BmapModeConfig(
      index: Int(bytes[0]),
      name: name,
      isUserEditable: bytes[3] & 0x01 != 0,
      isConfigured: bytes[configuredOffset] != 0 || bytes[promptOffset] != 0,
      cnc: Int(bytes[cncOffset]),
      spatial: spatial,
      windBlock: bytes[windOffset] != 0,
      ancEnabled: bytes[ancOffset] != 0
    )
  }
}

public enum BmapAudioModeError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case emptyPayload
  case indexOutOfRange(Int)
  case truncated(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "audio mode got unexpected address [\(fblock).\(function)]"
    case .emptyPayload:
      "audio mode payload is empty"
    case .indexOutOfRange(let index):
      "mode index \(index) is outside 0...255"
    case .truncated(let expected, let actual):
      "mode config payload too short: expected \(expected), actual \(actual)"
    }
  }
}
