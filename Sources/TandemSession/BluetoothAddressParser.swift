import Foundation

/// Recovers a Bluetooth address from a Core Audio device UID.
///
/// The UID is documented as an opaque identifier; that it contains the address is an
/// observation about the current system, not a contract. The parser is therefore
/// deliberately tolerant of separators and case, and callers must treat a `nil` as
/// "ask the user which device" rather than as an error.
public struct BluetoothAddressParser: Sendable {
  public init() {}

  public func address(fromDeviceUID uid: String) -> DeviceIdentity? {
    guard let raw = Self.firstAddress(in: uid) else { return nil }
    return DeviceIdentity(raw)
  }

  /// Six hexadecimal pairs joined by `-` or `:`, wherever they appear in the string.
  private static func firstAddress(in uid: String) -> String? {
    let pair = "[0-9A-Fa-f]{2}"
    // The guards reject a candidate that is merely part of a longer separated hex
    // run, such as a UUID fragment. Taking the first six pairs of one of those would
    // hand back an address that belongs to no device.
    let notContinuing = "(?<![0-9A-Fa-f])(?<![0-9A-Fa-f][-:])"
    let notContinued = "(?![0-9A-Fa-f])(?![-:][0-9A-Fa-f])"
    let pattern = "\(notContinuing)\(pair)([-:])(?:\(pair)\\1){4}\(pair)\(notContinued)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(uid.startIndex..<uid.endIndex, in: uid)
    guard let match = expression.firstMatch(in: uid, range: range),
      let matched = Range(match.range, in: uid)
    else {
      return nil
    }
    return String(uid[matched])
  }
}
