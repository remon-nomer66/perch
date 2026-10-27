import Foundation

/// Product-identity requests and parsers: the connect-time ping [0.1], firmware
/// version [0.5], and model name [1.2].
public enum BmapProductInfo {
  /// Builds the [0.1] GET that QC35 needs right after connecting: it stays silent
  /// until it receives one. On the wire this encodes to `00 01 01 00`.
  public static func initializeRequest() throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.initialize.fblock,
      function: BmapFunctionAddress.initialize.function,
      op: .get
    )
  }

  /// Builds the [0.5] GET for the main firmware version (Ultra 2). QC35 instead
  /// carries its firmware in the connect acknowledgement, not here.
  public static func firmwareRequest() throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.firmwareVersion.fblock,
      function: BmapFunctionAddress.firmwareVersion.function,
      op: .get
    )
  }

  /// Builds the [1.2] GET for the model name.
  public static func deviceNameRequest() throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.deviceName.fblock,
      function: BmapFunctionAddress.deviceName.function,
      op: .get
    )
  }

  /// Parses the [0.5] reply: the whole payload is the firmware string (ASCII).
  public static func parseFirmware(_ frame: BmapFrame) throws -> String {
    guard frame.address == .firmwareVersion else {
      throw BmapProductInfoError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapProductInfoError.unexpectedOperator(frame.op)
    }
    guard !frame.payload.isEmpty else {
      throw BmapProductInfoError.emptyPayload
    }
    guard let text = String(data: frame.payload, encoding: .utf8) else {
      throw BmapProductInfoError.invalidText
    }
    return text
  }

  /// Parses the [1.2] reply: byte 0 is a flag, the model name is the UTF-8 remainder.
  public static func parseDeviceName(_ frame: BmapFrame) throws -> String {
    guard frame.address == .deviceName else {
      throw BmapProductInfoError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapProductInfoError.unexpectedOperator(frame.op)
    }
    let bytes = frame.payload
    guard bytes.count >= 1 else {
      throw BmapProductInfoError.emptyPayload
    }
    guard let text = String(data: bytes.dropFirst(), encoding: .utf8) else {
      throw BmapProductInfoError.invalidText
    }
    return text
  }
}

public enum BmapProductInfoError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case unexpectedOperator(BmapOperator)
  case emptyPayload
  case invalidText

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "product info got unexpected address [\(fblock).\(function)]"
    case .unexpectedOperator(let op):
      "product info expected a STATUS/RESULT frame but got \(op)"
    case .emptyPayload:
      "product info payload is empty"
    case .invalidText:
      "product info payload is not valid UTF-8"
    }
  }
}
