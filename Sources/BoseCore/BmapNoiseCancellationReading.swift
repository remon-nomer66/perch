import Foundation

/// The noise-cancellation level read back from [1.5].
///
/// The byte order was contested between reference implementations; a live capture
/// of the slider settled it (byte 0 stays 0x0b, only byte 1 tracks the slider), so
/// this app reads `current = payload[1]` and `maximum = payload[0] - 1`. Do not copy
/// the reversed order some references used.
public struct BmapNoiseCancellationReading: Equatable, Sendable {
  /// The level the slider is at now: `payload[1]`.
  public let currentStep: Int
  /// The top of the range: `numSteps - 1`, i.e. `payload[0] - 1`.
  public let maximumStep: Int
  /// `flags` bit 0. The flag byte's meaning is single-source and unverified, so only
  /// bit 0 is interpreted and the whole byte is kept in `rawFlags` for callers that
  /// want to reason about it.
  public let isEnabled: Bool
  public let rawFlags: UInt8

  public init(currentStep: Int, maximumStep: Int, isEnabled: Bool, rawFlags: UInt8) {
    self.currentStep = currentStep
    self.maximumStep = maximumStep
    self.isEnabled = isEnabled
    self.rawFlags = rawFlags
  }
}

/// Reads [1.5], the noise-cancellation level. Read only: on Ultra 2 a write here
/// needs authentication, so level changes go through [31.10] (`BmapNoiseControlLiveWrite`).
public enum BmapNoiseCancellationReader {
  /// Builds the GET that asks for the current level.
  public static func readRequest() throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.noiseCancellationRead.fblock,
      function: BmapFunctionAddress.noiseCancellationRead.function,
      op: .get
    )
  }

  public static func parse(_ frame: BmapFrame) throws -> BmapNoiseCancellationReading {
    guard frame.address == .noiseCancellationRead else {
      throw BmapNoiseCancellationError.unexpectedAddress(
        fblock: frame.fblock, function: frame.function
      )
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapNoiseCancellationError.unexpectedOperator(frame.op)
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= 3 else {
      throw BmapNoiseCancellationError.truncated(expected: 3, actual: bytes.count)
    }
    return BmapNoiseCancellationReading(
      currentStep: Int(bytes[1]),
      maximumStep: Int(bytes[0]) - 1,
      isEnabled: bytes[2] & 0x01 != 0,
      rawFlags: bytes[2]
    )
  }
}

public enum BmapNoiseCancellationError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case unexpectedOperator(BmapOperator)
  case truncated(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "noise cancellation expected [1.5] but got [\(fblock).\(function)]"
    case .unexpectedOperator(let op):
      "noise cancellation expected a STATUS/RESULT frame but got \(op)"
    case .truncated(let expected, let actual):
      "noise cancellation payload too short: expected \(expected), actual \(actual)"
    }
  }
}
