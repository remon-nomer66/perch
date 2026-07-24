import Foundation

/// The error a device reports in an ERROR frame's `payload[0]`.
///
/// Two of these steer control flow rather than just being logged: `runtime` (8) is
/// what an Ultra 2 answers when asked to do something its current state forbids —
/// setting `autoCNC` to 1, or writing a preset mode slot — and `operatorNotSupported`
/// (5) is the "authentication required" refusal for writes the app is not allowed to
/// make. Values outside this list are still errors; see `BmapFrame.rawErrorCode`.
public enum BmapErrorCode: UInt8, Equatable, Sendable, CaseIterable {
  case length = 1
  case checksum = 2
  case fblockNotSupported = 3
  case functionNotSupported = 4
  /// The operator is refused for lack of authentication (a locked write).
  case operatorNotSupported = 5
  case invalidData = 6
  case dataUnavailable = 7
  /// The request is well-formed but the device's current state forbids it.
  case runtime = 8
  case timeout = 9
  case invalidState = 10
  case invalidTransition = 15
  case insecureTransport = 20
}

extension BmapFrame {
  /// True when this frame reports an error.
  public var isError: Bool { op == .error }

  /// The raw error byte, if this is an ERROR frame carrying one. Preserved even for
  /// codes this enum does not name, so an unrecognised failure is still visibly a
  /// failure to a caller that logs it.
  public var rawErrorCode: UInt8? {
    guard op == .error else { return nil }
    return payload.first
  }

  /// The recognised error code, if this is an ERROR frame carrying one that maps to
  /// a known `BmapErrorCode`.
  public var errorCode: BmapErrorCode? {
    guard let raw = rawErrorCode else { return nil }
    return BmapErrorCode(rawValue: raw)
  }
}
