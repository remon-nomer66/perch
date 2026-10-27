import Foundation

/// The live noise-control state written to [31.10] on Ultra 2.
///
/// This is the write path for the level [1.5] only reports: [1.5] itself needs auth,
/// so CNC, spatial audio, wind block, and ANC are all set together here in one
/// five-byte SETGET. The one field that is not exposed is `autoCNC` — it must always
/// be 0, because 1 makes the device answer with a runtime error, so it is written as
/// a constant rather than offered as a choice.
public struct BmapNoiseControlSetting: Equatable, Sendable {
  /// 0...10. Inverted in feel: 0 is maximum cancellation, 10 is maximum ambient.
  public let cnc: Int
  public let spatial: Spatial
  /// Wind block on/off. Note the audible CNC change only appears with `ancEnabled`
  /// on and `windBlock` off, because wind block masks the CNC DSP.
  public let windBlock: Bool
  public let ancEnabled: Bool

  public enum Spatial: UInt8, Equatable, Sendable, CaseIterable {
    case off = 0
    /// Fixed to the room.
    case room = 1
    /// Follows head movement.
    case head = 2
  }

  public init(cnc: Int, spatial: Spatial, windBlock: Bool, ancEnabled: Bool) {
    self.cnc = cnc
    self.spatial = spatial
    self.windBlock = windBlock
    self.ancEnabled = ancEnabled
  }
}

/// Builds and reads the [31.10] five-byte `[cnc, autoCNC, spatial, wind, anc]`.
public enum BmapNoiseControlLiveWrite {
  /// `autoCNC` is always 0; 1 is rejected with a runtime error, so it is not a field.
  private static let autoCNCDisabled: UInt8 = 0
  private static let cncRange = 0...10

  public static func writeRequest(_ setting: BmapNoiseControlSetting) throws -> BmapFrame {
    guard cncRange.contains(setting.cnc) else {
      throw BmapNoiseControlLiveWriteError.cncOutOfRange(setting.cnc)
    }
    let payload: [UInt8] = [
      UInt8(setting.cnc),
      autoCNCDisabled,
      setting.spatial.rawValue,
      setting.windBlock ? 1 : 0,
      setting.ancEnabled ? 1 : 0,
    ]
    return try BmapFrame(
      fblock: BmapFunctionAddress.noiseControlLiveWrite.fblock,
      function: BmapFunctionAddress.noiseControlLiveWrite.function,
      op: .setGet,
      payload: Data(payload)
    )
  }

  /// Reads the five-byte state back from the device's reply. `autoCNC` (byte 1) is
  /// not surfaced: it is a device-managed field the app never sets to anything but 0.
  public static func parse(_ frame: BmapFrame) throws -> BmapNoiseControlSetting {
    guard frame.address == .noiseControlLiveWrite else {
      throw BmapNoiseControlLiveWriteError.unexpectedAddress(
        fblock: frame.fblock, function: frame.function
      )
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= 5 else {
      throw BmapNoiseControlLiveWriteError.truncated(expected: 5, actual: bytes.count)
    }
    guard let spatial = BmapNoiseControlSetting.Spatial(rawValue: bytes[2]) else {
      throw BmapNoiseControlLiveWriteError.invalidSpatial(bytes[2])
    }
    // Validate cnc on the way in too, symmetric with writeRequest: a read-back is fed
    // straight back into a write, so an out-of-range value from a misbehaving device
    // must fail here rather than surface later as a puzzling write rejection.
    let cnc = Int(bytes[0])
    guard cncRange.contains(cnc) else {
      throw BmapNoiseControlLiveWriteError.cncOutOfRange(cnc)
    }
    return BmapNoiseControlSetting(
      cnc: cnc,
      spatial: spatial,
      windBlock: bytes[3] != 0,
      ancEnabled: bytes[4] != 0
    )
  }
}

public enum BmapNoiseControlLiveWriteError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case cncOutOfRange(Int)
  case invalidSpatial(UInt8)
  case truncated(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "noise-control write expected [31.10] but got [\(fblock).\(function)]"
    case .cncOutOfRange(let value):
      "cnc \(value) is outside 0...10"
    case .invalidSpatial(let value):
      "invalid spatial mode \(value) (defined 0...2)"
    case .truncated(let expected, let actual):
      "noise-control payload too short: expected \(expected), actual \(actual)"
    }
  }
}
