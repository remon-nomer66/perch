import Foundation

/// A BMAP function address: the `(fblock, function)` pair that names one feature.
///
/// Hashable so a device config can carry the set of addresses a model exposes, and
/// the session layer can route an incoming frame to the matching parser without a
/// giant switch.
public struct BmapFunctionAddress: Equatable, Hashable, Sendable {
  public let fblock: UInt8
  public let function: UInt8

  public init(fblock: UInt8, function: UInt8) {
    self.fblock = fblock
    self.function = function
  }
}

/// The function blocks (the `fblock` byte) this app addresses. Kept as named
/// constants so the numbers appear once, not scattered through the parsers.
public enum BmapFunctionBlock {
  public static let productInfo: UInt8 = 0
  public static let settings: UInt8 = 1
  public static let status: UInt8 = 2
  public static let audioModes: UInt8 = 31
}

extension BmapFunctionAddress {
  // Product-info block (fblock 0).

  /// [0.1] — the ping QC35 needs after connecting before it answers anything.
  public static let initialize = BmapFunctionAddress(
    fblock: BmapFunctionBlock.productInfo, function: 1
  )
  /// [0.5] — main firmware version as an ASCII string (Ultra 2).
  public static let firmwareVersion = BmapFunctionAddress(
    fblock: BmapFunctionBlock.productInfo, function: 5
  )

  // Settings block (fblock 1).

  /// [1.2] — model name: `[flag, ...UTF-8]`.
  public static let deviceName = BmapFunctionAddress(
    fblock: BmapFunctionBlock.settings, function: 2
  )
  /// [1.5] — noise-cancellation level, read only (writing here needs auth on Ultra 2).
  public static let noiseCancellationRead = BmapFunctionAddress(
    fblock: BmapFunctionBlock.settings, function: 5
  )
  /// [1.6] — QC35 adaptive noise reduction (ANR).
  public static let adaptiveNoiseReduction = BmapFunctionAddress(
    fblock: BmapFunctionBlock.settings, function: 6
  )
  /// [1.7] — Ultra 2 three-band equalizer.
  public static let equalizer = BmapFunctionAddress(
    fblock: BmapFunctionBlock.settings, function: 7
  )

  // Status block (fblock 2).

  /// [2.2] — battery level(s).
  public static let battery = BmapFunctionAddress(
    fblock: BmapFunctionBlock.status, function: 2
  )

  // Audio-modes block (fblock 31).

  /// [31.6] — per-mode configuration (partly unresolved; see `BoseModeConfig`).
  public static let modeConfig = BmapFunctionAddress(
    fblock: BmapFunctionBlock.audioModes, function: 6
  )
  /// [31.10] — live write of CNC / spatial / wind / ANC on Ultra 2.
  public static let noiseControlLiveWrite = BmapFunctionAddress(
    fblock: BmapFunctionBlock.audioModes, function: 10
  )
}
