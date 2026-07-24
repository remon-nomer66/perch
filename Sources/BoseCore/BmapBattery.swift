import Foundation

/// One battery reading from a device: a percentage, an optional estimate of the
/// minutes left, and which physical component it belongs to on a multi-part product.
public struct BmapBatteryComponent: Equatable, Sendable {
  public let percent: Int
  /// Estimated minutes remaining, or `nil` when the device reports 0xFFFF (unknown).
  public let minutesRemaining: Int?
  /// Which component this reading is for (left bud, right bud, case, …). The meaning
  /// of each id is device-defined, so it is kept raw rather than mapped to a name
  /// this protocol layer would have to guess. `nil` for the single-byte QC35 shape,
  /// which reports one whole-headset percentage with no component tag.
  public let componentId: UInt8?

  public init(percent: Int, minutesRemaining: Int?, componentId: UInt8?) {
    self.percent = percent
    self.minutesRemaining = minutesRemaining
    self.componentId = componentId
  }
}

/// Parses the [2.2] battery status. The two payload shapes are a config axis
/// (`BoseDeviceConfig.batteryLayout`), never guessed from the payload length: QC35
/// answers with a single percentage byte, Ultra 2 with one four-byte group per
/// component.
public enum BmapBattery {
  /// The layout of a [2.2] payload. Selected per model from config.
  public enum Layout: Equatable, Sendable {
    /// QC35: `[pct]` — one whole-headset percentage.
    case singleByte
    /// Ultra 2: repeated `[pct, remaining_hi, remaining_lo, componentId]` groups.
    case componentGroups
  }

  /// 0xFFFF in the two remaining-minutes bytes means the device does not know yet.
  private static let unknownRemaining: UInt16 = 0xFFFF

  public static func parse(
    _ frame: BmapFrame,
    layout: Layout
  ) throws -> [BmapBatteryComponent] {
    let bytes = try payload(of: frame)
    switch layout {
    case .singleByte:
      guard let first = bytes.first else {
        throw BmapBatteryError.emptyPayload
      }
      return [
        BmapBatteryComponent(
          percent: try percentage(first),
          minutesRemaining: nil,
          componentId: nil
        )
      ]

    case .componentGroups:
      guard !bytes.isEmpty else {
        throw BmapBatteryError.emptyPayload
      }
      guard bytes.count.isMultiple(of: 4) else {
        throw BmapBatteryError.malformedComponentGroups(bytes.count)
      }
      var components: [BmapBatteryComponent] = []
      components.reserveCapacity(bytes.count / 4)
      for start in stride(from: 0, to: bytes.count, by: 4) {
        let remainingRaw = (UInt16(bytes[start + 1]) << 8) | UInt16(bytes[start + 2])
        components.append(
          BmapBatteryComponent(
            percent: try percentage(bytes[start]),
            minutesRemaining: remainingRaw == unknownRemaining ? nil : Int(remainingRaw),
            componentId: bytes[start + 3]
          )
        )
      }
      return components
    }
  }

  private static func percentage(_ byte: UInt8) throws -> Int {
    let value = Int(byte)
    guard (0...100).contains(value) else {
      throw BmapBatteryError.percentOutOfRange(value)
    }
    return value
  }

  private static func payload(of frame: BmapFrame) throws -> [UInt8] {
    guard frame.address == .battery else {
      throw BmapBatteryError.unexpectedAddress(fblock: frame.fblock, function: frame.function)
    }
    guard frame.op == .status || frame.op == .result else {
      throw BmapBatteryError.unexpectedOperator(frame.op)
    }
    return [UInt8](frame.payload)
  }
}

public enum BmapBatteryError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedAddress(fblock: UInt8, function: UInt8)
  case unexpectedOperator(BmapOperator)
  case emptyPayload
  case malformedComponentGroups(Int)
  case percentOutOfRange(Int)

  public var description: String {
    switch self {
    case .unexpectedAddress(let fblock, let function):
      "battery expected [2.2] but got [\(fblock).\(function)]"
    case .unexpectedOperator(let op):
      "battery expected a STATUS/RESULT frame but got \(op)"
    case .emptyPayload:
      "battery payload is empty"
    case .malformedComponentGroups(let count):
      "battery component payload \(count) is not a multiple of 4"
    case .percentOutOfRange(let value):
      "battery percent \(value) is outside 0...100"
    }
  }
}
