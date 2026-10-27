import Foundation

/// The [1.6] adaptive noise-reduction status on QC35: a level and a capability byte.
public struct BmapAdaptiveNoiseReductionStatus: Equatable, Sendable {
  /// The wire level. No label is baked on: 0 / 1 / 3 are the confirmed off / high /
  /// low values, and 2 (wind) is single-source and most likely unsupported on QC35,
  /// so callers map the wire value themselves rather than trust a name coined here.
  public let level: UInt8
  public let capabilities: UInt8

  public init(level: UInt8, capabilities: UInt8) {
    self.level = level
    self.capabilities = capabilities
  }
}

/// Builds and reads QC35's [1.6] adaptive noise reduction.
///
/// SETGET is `01 06 02 01 <level>`, STATUS is `01 06 03 02 <level> <capabilities>`.
/// The confirmed wire levels are provided as named constants; the setter still takes
/// a raw `UInt8` so a model that defines more values is not boxed in by this app.
public enum BmapAdaptiveNoiseReduction {
  public static let levelOff: UInt8 = 0
  public static let levelHigh: UInt8 = 1
  public static let levelLow: UInt8 = 3

  public static func setRequest(level: UInt8) throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.adaptiveNoiseReduction.fblock,
      function: BmapFunctionAddress.adaptiveNoiseReduction.function,
      op: .setGet,
      payload: Data([level])
    )
  }

  public static func parseStatus(_ frame: BmapFrame) throws -> BmapAdaptiveNoiseReductionStatus {
    guard frame.address == .adaptiveNoiseReduction else {
      throw BmapAdaptiveNoiseReductionError.unexpectedAddress(
        fblock: frame.fblock, function: frame.function
      )
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapAdaptiveNoiseReductionError.unexpectedOperator(frame.op)
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= 2 else {
      throw BmapAdaptiveNoiseReductionError.truncated(expected: 2, actual: bytes.count)
    }
    return BmapAdaptiveNoiseReductionStatus(level: bytes[0], capabilities: bytes[1])
  }
}

public enum BmapAdaptiveNoiseReductionError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case unexpectedOperator(BmapOperator)
  case truncated(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "adaptive noise reduction expected [1.6] but got [\(fblock).\(function)]"
    case .unexpectedOperator(let op):
      "adaptive noise reduction expected a STATUS/RESULT frame but got \(op)"
    case .truncated(let expected, let actual):
      "adaptive noise reduction payload too short: expected \(expected), actual \(actual)"
    }
  }
}
