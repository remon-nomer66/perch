import Foundation

/// One equalizer band read from [1.7]: its id and its signed range and value.
///
/// Every byte is a signed int8. The captured range is min -10 (0xf6) to max +10
/// (0x0a); band ids are 0 = Bass, 1 = Mid, 2 = Treble.
public struct BmapEqualizerBand: Equatable, Sendable {
  public let bandId: UInt8
  public let minimum: Int
  public let maximum: Int
  public let current: Int

  public init(bandId: UInt8, minimum: Int, maximum: Int, current: Int) {
    self.bandId = bandId
    self.minimum = minimum
    self.maximum = maximum
    self.current = current
  }
}

/// Reads and writes Ultra 2's three-band equalizer [1.7].
///
/// GET returns one `[min, max, current, band_id]` group per band, all signed int8.
/// A write is `[value & 0xFF, band_id]` — two bytes — and each band is sent as its
/// own frame; there is no single frame that sets all three at once.
public enum BmapEqualizer {
  public static let bassBandId: UInt8 = 0
  public static let midBandId: UInt8 = 1
  public static let trebleBandId: UInt8 = 2

  /// Builds the GET that asks for every band's range and value.
  public static func readRequest() throws -> BmapFrame {
    try BmapFrame(
      fblock: BmapFunctionAddress.equalizer.fblock,
      function: BmapFunctionAddress.equalizer.function,
      op: .get
    )
  }

  public static func parseBands(_ frame: BmapFrame) throws -> [BmapEqualizerBand] {
    guard frame.address == .equalizer else {
      throw BmapEqualizerError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapEqualizerError.unexpectedOperator(frame.op)
    }
    let bytes = [UInt8](frame.payload)
    guard !bytes.isEmpty else {
      throw BmapEqualizerError.emptyPayload
    }
    guard bytes.count.isMultiple(of: 4) else {
      throw BmapEqualizerError.malformedBandGroups(bytes.count)
    }
    return stride(from: 0, to: bytes.count, by: 4).map { start in
      BmapEqualizerBand(
        bandId: bytes[start + 3],
        minimum: Int(Int8(bitPattern: bytes[start])),
        maximum: Int(Int8(bitPattern: bytes[start + 1])),
        current: Int(Int8(bitPattern: bytes[start + 2]))
      )
    }
  }

  /// Builds the write for one band. `range`, when passed, gates the value against the
  /// band range the device declared in its GET reply; left `nil` only the signed-byte
  /// limit is enforced, since the true range comes from the device, not this layer.
  public static func setRequest(
    bandId: UInt8,
    value: Int,
    range: ClosedRange<Int>? = nil
  ) throws -> BmapFrame {
    if let range, !range.contains(value) {
      throw BmapEqualizerError.valueOutOfRange(value: value, minimum: range.lowerBound, maximum: range.upperBound)
    }
    guard (Int(Int8.min)...Int(Int8.max)).contains(value) else {
      throw BmapEqualizerError.valueOutOfRange(value: value, minimum: Int(Int8.min), maximum: Int(Int8.max))
    }
    let payload: [UInt8] = [UInt8(bitPattern: Int8(value)), bandId]
    return try BmapFrame(
      fblock: BmapFunctionAddress.equalizer.fblock,
      function: BmapFunctionAddress.equalizer.function,
      op: .setGet,
      payload: Data(payload)
    )
  }

  /// Convenience over `setRequest` for writing several bands at once: one frame per
  /// band, in the order given, because the device takes them one at a time.
  public static func setRequests(
    _ bands: [(bandId: UInt8, value: Int)],
    range: ClosedRange<Int>? = nil
  ) throws -> [BmapFrame] {
    try bands.map { try setRequest(bandId: $0.bandId, value: $0.value, range: range) }
  }
}

public enum BmapEqualizerError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case unexpectedOperator(BmapOperator)
  case emptyPayload
  case malformedBandGroups(Int)
  case valueOutOfRange(value: Int, minimum: Int, maximum: Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "equalizer expected [1.7] but got [\(fblock).\(function)]"
    case .unexpectedOperator(let op):
      "equalizer expected a STATUS/RESULT frame but got \(op)"
    case .emptyPayload:
      "equalizer payload is empty"
    case .malformedBandGroups(let count):
      "equalizer band payload \(count) is not a multiple of 4"
    case .valueOutOfRange(let value, let minimum, let maximum):
      "equalizer value \(value) is outside \(minimum)...\(maximum)"
    }
  }
}
