import Foundation

public enum TandemGeneralSettingSlot: UInt8, CaseIterable, Equatable, Sendable {
  case one = 0xD1
  case two = 0xD2
  case three = 0xD3
  case four = 0xD4
}

public enum TandemGeneralSettingType: UInt8, Equatable, Sendable {
  case boolean = 0
  case list = 1
}

public enum TandemGeneralStringFormat: UInt8, Equatable, Sendable {
  case rawName = 0
  case enumName = 1
}

public struct TandemGeneralString: Equatable, Sendable {
  public let format: TandemGeneralStringFormat
  public let title: String
  public let summary: String

  public init(format: TandemGeneralStringFormat, title: String, summary: String) {
    self.format = format
    self.title = title
    self.summary = summary
  }
}

public struct TandemGeneralSettingCapability: Equatable, Sendable {
  public let slot: TandemGeneralSettingSlot
  public let type: TandemGeneralSettingType
  public let label: TandemGeneralString
  public let listValues: [TandemGeneralString]

  public init(
    slot: TandemGeneralSettingSlot,
    type: TandemGeneralSettingType,
    label: TandemGeneralString,
    listValues: [TandemGeneralString]
  ) {
    self.slot = slot
    self.type = type
    self.label = label
    self.listValues = listValues
  }

  public var isSidetone: Bool {
    label.format == .enumName && label.title == "SIDETONE_SETTING"
  }
}

public enum TandemGeneralSettingValue: Equatable, Sendable {
  case boolean(Bool)
  case list(Int)
}

public struct TandemGeneralSettingSnapshot: Equatable, Sendable {
  public let capability: TandemGeneralSettingCapability
  public let isControlEnabled: Bool
  public let value: TandemGeneralSettingValue

  public init(
    capability: TandemGeneralSettingCapability,
    isControlEnabled: Bool,
    value: TandemGeneralSettingValue
  ) {
    self.capability = capability
    self.isControlEnabled = isControlEnabled
    self.value = value
  }
}

public enum TandemGeneralSettingError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedPayload(expected: [UInt8], actual: [UInt8])
  case invalidLength(Int)
  case invalidSlot(UInt8)
  case invalidType(UInt8)
  case invalidEnableDisable(UInt8)
  case invalidValue(UInt8)
  case invalidStringFormat(UInt8)
  case invalidString(offset: Int)
  case invalidUTF8(offset: Int)
  case listCountMismatch(expected: Int, actual: Int)
  case typeMismatch

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      String(format: "unexpected Tandem data type 0x%02X", value)
    case .unexpectedPayload(let expected, let actual):
      "unexpected general-setting payload prefix \(actual); expected \(expected)"
    case .invalidLength(let length): "invalid general-setting payload length \(length)"
    case .invalidSlot(let value): String(format: "invalid general-setting slot 0x%02X", value)
    case .invalidType(let value): "invalid general-setting type \(value)"
    case .invalidEnableDisable(let value): "invalid enable/disable value \(value)"
    case .invalidValue(let value): "invalid general-setting value \(value)"
    case .invalidStringFormat(let value): "invalid general-setting string format \(value)"
    case .invalidString(let offset): "invalid general-setting string at offset \(offset)"
    case .invalidUTF8(let offset): "invalid UTF-8 at offset \(offset)"
    case .listCountMismatch(let expected, let actual):
      "general-setting list count mismatch: expected \(expected), actual \(actual)"
    case .typeMismatch: "general-setting type mismatch"
    }
  }
}

public enum TandemGeneralSettingProtocol {
  private static let getCapability: UInt8 = 0xD0
  private static let returnCapability: UInt8 = 0xD1
  private static let getStatus: UInt8 = 0xD2
  private static let returnStatus: UInt8 = 0xD3
  private static let notifyStatus: UInt8 = 0xD5
  private static let getParameter: UInt8 = 0xD6
  private static let returnParameter: UInt8 = 0xD7
  private static let setParameter: UInt8 = 0xD8
  private static let notifyParameter: UInt8 = 0xD9
  private static let japaneseDisplayLanguage: UInt8 = 0x0B

  public static func capabilityRequest(
    sequence: UInt8,
    slot: TandemGeneralSettingSlot
  ) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [getCapability, slot.rawValue, japaneseDisplayLanguage]
    )
  }

  public static func statusRequest(
    sequence: UInt8,
    slot: TandemGeneralSettingSlot
  ) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getStatus, slot.rawValue])
  }

  public static func parameterRequest(
    sequence: UInt8,
    slot: TandemGeneralSettingSlot
  ) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getParameter, slot.rawValue])
  }

  /// The single-byte value field cannot encode past this even if a device were to
  /// declare more list entries; kept as the last line of defence when no
  /// capability is passed.
  private static let wireListIndexRange = 0...63

  /// Builds the write for a slot.
  ///
  /// When the device's declared `capability` is passed, the value is checked
  /// against it before anything reaches the wire: the declared type must match
  /// and a list index must name an entry the device actually listed. The
  /// parameter is optional so existing call sites keep compiling; new callers
  /// should pass it.
  public static func setParameterRequest(
    sequence: UInt8,
    slot: TandemGeneralSettingSlot,
    value: TandemGeneralSettingValue,
    capability: TandemGeneralSettingCapability? = nil
  ) throws -> TandemFrame {
    if let capability {
      // A capability describes exactly one slot; pairing it with another slot's
      // write is a caller bug, not something to send and let the device sort out.
      guard capability.slot == slot else {
        throw TandemGeneralSettingError.invalidSlot(slot.rawValue)
      }
      switch value {
      case .boolean:
        guard capability.type == .boolean else {
          throw TandemGeneralSettingError.typeMismatch
        }
      case .list(let index):
        guard capability.type == .list else {
          throw TandemGeneralSettingError.typeMismatch
        }
        guard (0..<capability.listValues.count).contains(index) else {
          throw TandemGeneralSettingError.invalidValue(UInt8(truncatingIfNeeded: index))
        }
      }
    }
    let typeAndValue: (UInt8, UInt8)
    switch value {
    case .boolean(let enabled):
      typeAndValue = (TandemGeneralSettingType.boolean.rawValue, enabled ? 0x00 : 0x01)
    case .list(let index):
      guard wireListIndexRange.contains(index) else {
        throw TandemGeneralSettingError.invalidValue(UInt8(truncatingIfNeeded: index))
      }
      typeAndValue = (TandemGeneralSettingType.list.rawValue, UInt8(index))
    }
    return try request(
      sequence: sequence,
      payload: [setParameter, slot.rawValue, typeAndValue.0, typeAndValue.1]
    )
  }

  public static func parseCapabilityResponse(
    _ frame: TandemFrame
  ) throws -> TandemGeneralSettingCapability {
    let bytes = try table1Bytes(frame)
    guard bytes.count >= 4, bytes[0] == returnCapability else {
      throw TandemGeneralSettingError.unexpectedPayload(
        expected: [returnCapability],
        actual: Array(bytes.prefix(1))
      )
    }
    guard let slot = TandemGeneralSettingSlot(rawValue: bytes[1]) else {
      throw TandemGeneralSettingError.invalidSlot(bytes[1])
    }
    guard let type = TandemGeneralSettingType(rawValue: bytes[2]) else {
      throw TandemGeneralSettingError.invalidType(bytes[2])
    }
    var offset = 3
    let label = try parseString(bytes, offset: &offset)
    var listValues: [TandemGeneralString] = []
    if type == .list {
      guard offset < bytes.count else {
        throw TandemGeneralSettingError.invalidLength(bytes.count)
      }
      let count = Int(bytes[offset])
      offset += 1
      while offset < bytes.count {
        listValues.append(try parseString(bytes, offset: &offset))
      }
      guard listValues.count == count else {
        throw TandemGeneralSettingError.listCountMismatch(
          expected: count,
          actual: listValues.count
        )
      }
    }
    guard offset == bytes.count else {
      throw TandemGeneralSettingError.invalidLength(bytes.count)
    }
    return TandemGeneralSettingCapability(
      slot: slot,
      type: type,
      label: label,
      listValues: listValues
    )
  }

  public static func parseStatusResponse(
    _ frame: TandemFrame,
    slot: TandemGeneralSettingSlot
  ) throws -> Bool {
    try parseStatus(frame, command: returnStatus, slot: slot)
  }

  public static func parseStatusNotification(
    _ frame: TandemFrame,
    slot: TandemGeneralSettingSlot
  ) throws -> Bool {
    try parseStatus(frame, command: notifyStatus, slot: slot)
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    capability: TandemGeneralSettingCapability
  ) throws -> TandemGeneralSettingValue {
    try parseValue(frame, command: returnParameter, capability: capability)
  }

  public static func parseParameterNotification(
    _ frame: TandemFrame,
    capability: TandemGeneralSettingCapability
  ) throws -> TandemGeneralSettingValue {
    try parseValue(frame, command: notifyParameter, capability: capability)
  }

  private static func parseStatus(
    _ frame: TandemFrame,
    command: UInt8,
    slot: TandemGeneralSettingSlot
  ) throws -> Bool {
    let bytes = try table1Bytes(frame)
    let expected = [command, slot.rawValue]
    guard bytes.count >= 2, Array(bytes.prefix(2)) == expected else {
      throw TandemGeneralSettingError.unexpectedPayload(
        expected: expected,
        actual: Array(bytes.prefix(2))
      )
    }
    guard bytes.count == 3 else { throw TandemGeneralSettingError.invalidLength(bytes.count) }
    guard bytes[2] == 0 || bytes[2] == 1 else {
      throw TandemGeneralSettingError.invalidEnableDisable(bytes[2])
    }
    return bytes[2] == 0
  }

  private static func parseValue(
    _ frame: TandemFrame,
    command: UInt8,
    capability: TandemGeneralSettingCapability
  ) throws -> TandemGeneralSettingValue {
    let bytes = try table1Bytes(frame)
    let expected = [command, capability.slot.rawValue]
    guard bytes.count >= 2, Array(bytes.prefix(2)) == expected else {
      throw TandemGeneralSettingError.unexpectedPayload(
        expected: expected,
        actual: Array(bytes.prefix(2))
      )
    }
    guard bytes.count == 4 else { throw TandemGeneralSettingError.invalidLength(bytes.count) }
    guard bytes[2] == capability.type.rawValue else {
      throw TandemGeneralSettingError.typeMismatch
    }
    switch capability.type {
    case .boolean:
      guard bytes[3] == 0 || bytes[3] == 1 else {
        throw TandemGeneralSettingError.invalidValue(bytes[3])
      }
      return .boolean(bytes[3] == 0)
    case .list:
      let index = Int(bytes[3])
      guard index < capability.listValues.count else {
        throw TandemGeneralSettingError.invalidValue(bytes[3])
      }
      return .list(index)
    }
  }

  private static func parseString(
    _ bytes: [UInt8],
    offset: inout Int
  ) throws -> TandemGeneralString {
    let start = offset
    guard offset + 2 <= bytes.count else {
      throw TandemGeneralSettingError.invalidString(offset: start)
    }
    guard let format = TandemGeneralStringFormat(rawValue: bytes[offset]) else {
      throw TandemGeneralSettingError.invalidStringFormat(bytes[offset])
    }
    offset += 1
    let titleLength = Int(bytes[offset])
    offset += 1
    guard offset + titleLength < bytes.count else {
      throw TandemGeneralSettingError.invalidString(offset: start)
    }
    let titleOffset = offset
    let titleData = Data(bytes[offset..<(offset + titleLength)])
    guard let title = String(data: titleData, encoding: .utf8) else {
      throw TandemGeneralSettingError.invalidUTF8(offset: titleOffset)
    }
    offset += titleLength
    let summaryLength = Int(bytes[offset])
    offset += 1
    guard offset + summaryLength <= bytes.count else {
      throw TandemGeneralSettingError.invalidString(offset: start)
    }
    let summaryOffset = offset
    let summaryData = Data(bytes[offset..<(offset + summaryLength)])
    guard let summary = String(data: summaryData, encoding: .utf8) else {
      throw TandemGeneralSettingError.invalidUTF8(offset: summaryOffset)
    }
    offset += summaryLength
    return TandemGeneralString(format: format, title: title, summary: summary)
  }

  private static func request(sequence: UInt8, payload: [UInt8]) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: sequence,
      payload: Data(payload)
    )
  }

  private static func table1Bytes(_ frame: TandemFrame) throws -> [UInt8] {
    guard frame.dataType == TandemFrame.table1DataType else {
      throw TandemGeneralSettingError.unexpectedDataType(frame.dataType)
    }
    return [UInt8](frame.payload)
  }
}
