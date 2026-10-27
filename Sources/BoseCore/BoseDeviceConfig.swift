import Foundation

/// Everything about a model that varies between devices, kept as data so nothing
/// model-specific is baked into the protocol code (per the project rule against
/// hard-coding device values). The axes follow the frozen spec's config list:
/// RFCOMM channel, whether a connect-time init is needed, which function addresses
/// the model exposes, the battery payload shape, and the mode-slot ranges.
public struct BoseDeviceConfig: Equatable, Sendable {
  /// The RFCOMM channel the control service lives on. Fully model-dependent
  /// (QC35 = 8, Ultra 2 = 2) and impossible to guess, so it must come from here.
  public let rfcommChannel: Int
  /// The address to GET right after connecting, or `nil` when the device answers
  /// without one. QC35 stays silent until it receives [0.1]; Ultra 2 needs nothing.
  public let initializeAddress: BmapFunctionAddress?
  /// The function addresses this model exposes, so the app never sends a GET the
  /// device would refuse with FblockNotSupported / FuncNotSupported.
  public let features: Set<BmapFunctionAddress>
  /// The shape of the [2.2] battery payload for this model — a config choice, never
  /// sniffed from the payload length.
  public let batteryLayout: BmapBattery.Layout
  /// The user-editable mode slots for block 31, or `nil` on models without block 31
  /// (QC35). From the frozen spec: editable = 4..<11.
  public let editableSlots: Range<Int>?
  /// The preset (locked) mode slots, or `nil` without block 31. Preset = 0..<4.
  public let presetSlots: Range<Int>?
  /// Whether the model actually exposes wind-noise reduction. The [31.10] block always
  /// carries a wind byte for the Ultra 2 family, so its presence in the payload cannot
  /// tell headphones (which have the feature) from earbuds (which do not). This axis
  /// gates the switch so a model without the physical feature never shows it, even
  /// though the wire byte is there.
  public let supportsWindReduction: Bool

  public init(
    rfcommChannel: Int,
    initializeAddress: BmapFunctionAddress?,
    features: Set<BmapFunctionAddress>,
    batteryLayout: BmapBattery.Layout,
    editableSlots: Range<Int>?,
    presetSlots: Range<Int>?,
    supportsWindReduction: Bool = true
  ) {
    self.rfcommChannel = rfcommChannel
    self.initializeAddress = initializeAddress
    self.features = features
    self.batteryLayout = batteryLayout
    self.editableSlots = editableSlots
    self.presetSlots = presetSlots
    self.supportsWindReduction = supportsWindReduction
  }

  /// Whether the model exposes the audio-modes block (block 31).
  public var supportsModeBlock: Bool { editableSlots != nil }

  /// Every mode slot the model declares — the presets plus the user-editable ones, in
  /// slot order. The range to walk when enumerating [31.6] configs, so the scan follows
  /// the declared capability instead of a baked-in `0...10`. Empty without block 31.
  public var modeSlots: [Int] {
    let all = Set(presetSlots ?? 0..<0).union(editableSlots ?? 0..<0)
    return all.sorted()
  }

  public func supports(_ address: BmapFunctionAddress) -> Bool {
    features.contains(address)
  }

  /// Builds the connect-time init frame, if the model needs one. Kept as a method
  /// rather than a stored frame so the config stays pure data (an address) and frame
  /// validation is not forced at declaration time.
  public func makeInitializeFrame() throws -> BmapFrame? {
    guard let address = initializeAddress else { return nil }
    return try BmapFrame(fblock: address.fblock, function: address.function, op: .get)
  }
}

extension BoseDeviceConfig {
  /// QC Ultra 2 family (Ultra Headphones 2nd Gen, Ultra Earbuds 2nd Gen): channel 2,
  /// no connect init, three-band EQ, live noise-control writes via [31.10], and the
  /// four-byte-per-component battery shape.
  public static let qcUltra2 = BoseDeviceConfig(
    rfcommChannel: 2,
    initializeAddress: nil,
    features: [
      .battery,
      .noiseCancellationRead,
      .equalizer,
      .noiseControlLiveWrite,
      .modeConfig,
      .firmwareVersion,
      .deviceName,
    ],
    batteryLayout: .componentGroups,
    editableSlots: 4..<11,
    presetSlots: 0..<4
  )

  /// QC Ultra Earbuds (2nd Gen): the same Ultra 2 dialect as the headphones, but the
  /// earbuds do not carry wind-noise reduction, so the switch is withheld even though the
  /// [31.10] wind byte is present on the wire.
  public static let qcUltra2Earbuds = BoseDeviceConfig(
    rfcommChannel: 2,
    initializeAddress: nil,
    features: [
      .battery,
      .noiseCancellationRead,
      .equalizer,
      .noiseControlLiveWrite,
      .modeConfig,
      .firmwareVersion,
      .deviceName,
    ],
    batteryLayout: .componentGroups,
    editableSlots: 4..<11,
    presetSlots: 0..<4,
    supportsWindReduction: false
  )

  /// QC35 family (QC35, QC35 II): channel 8, a required [0.1] connect init, adaptive
  /// noise reduction via [1.6], single-byte battery, and no block 31 or EQ.
  public static let qc35 = BoseDeviceConfig(
    rfcommChannel: 8,
    initializeAddress: .initialize,
    features: [
      .battery,
      .noiseCancellationRead,
      .adaptiveNoiseReduction,
      .deviceName,
    ],
    batteryLayout: .singleByte,
    editableSlots: nil,
    presetSlots: nil
  )
}
