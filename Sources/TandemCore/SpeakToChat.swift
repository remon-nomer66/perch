import Foundation

public enum TandemSpeakToChatSensitivity: UInt8, CaseIterable, Hashable, Sendable {
  case automatic = 0
  case high = 1
  case low = 2
}

public enum TandemSpeakToChatTimeout: UInt8, CaseIterable, Hashable, Sendable {
  case fast = 0
  case medium = 1
  case slow = 2
  case none = 3
}

public enum TandemSpeakToChatEffectStatus: UInt8, Equatable, Sendable {
  case notActive = 0
  case active = 1
}

public struct TandemSpeakToChatCapability: Equatable, Sendable {
  public let supportsPreview: Bool
  public let fastSeconds: Int
  public let mediumSeconds: Int
  public let slowSeconds: Int

  public init(
    supportsPreview: Bool,
    fastSeconds: Int,
    mediumSeconds: Int,
    slowSeconds: Int
  ) {
    self.supportsPreview = supportsPreview
    self.fastSeconds = fastSeconds
    self.mediumSeconds = mediumSeconds
    self.slowSeconds = slowSeconds
  }

  public func seconds(for timeout: TandemSpeakToChatTimeout) -> Int? {
    switch timeout {
    case .fast: fastSeconds
    case .medium: mediumSeconds
    case .slow: slowSeconds
    case .none: nil
    }
  }
}

public struct TandemSpeakToChatSnapshot: Equatable, Sendable {
  public let capability: TandemSpeakToChatCapability
  public let isControlEnabled: Bool
  public let effectStatus: TandemSpeakToChatEffectStatus
  public let isEnabled: Bool
  /// The second firmware field is preserved verbatim until its UI semantics are
  /// verified for each model.  It must not be overwritten when toggling field 1.
  public let secondarySettingEnabled: Bool
  public let sensitivity: TandemSpeakToChatSensitivity
  public let timeout: TandemSpeakToChatTimeout

  public init(
    capability: TandemSpeakToChatCapability,
    isControlEnabled: Bool,
    effectStatus: TandemSpeakToChatEffectStatus,
    isEnabled: Bool,
    secondarySettingEnabled: Bool,
    sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout
  ) {
    self.capability = capability
    self.isControlEnabled = isControlEnabled
    self.effectStatus = effectStatus
    self.isEnabled = isEnabled
    self.secondarySettingEnabled = secondarySettingEnabled
    self.sensitivity = sensitivity
    self.timeout = timeout
  }
}

public enum TandemSpeakToChatError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedPayload(expected: [UInt8], actual: [UInt8])
  case invalidLength(Int)
  case invalidEnableDisable(UInt8)
  case invalidOnOff(UInt8)
  case invalidEffectStatus(UInt8)
  case invalidPreview(UInt8)
  case invalidSensitivity(UInt8)
  case invalidTimeout(UInt8)

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      String(format: "unexpected Tandem data type 0x%02X", value)
    case .unexpectedPayload(let expected, let actual):
      "unexpected Speak-to-Chat payload prefix \(actual); expected \(expected)"
    case .invalidLength(let length): "invalid Speak-to-Chat payload length \(length)"
    case .invalidEnableDisable(let value): "invalid enable/disable value \(value)"
    case .invalidOnOff(let value): "invalid on/off value \(value)"
    case .invalidEffectStatus(let value): "invalid effect status \(value)"
    case .invalidPreview(let value): "invalid preview capability \(value)"
    case .invalidSensitivity(let value): "invalid detection sensitivity \(value)"
    case .invalidTimeout(let value): "invalid mode-out timeout \(value)"
    }
  }
}

public enum TandemSpeakToChatProtocol {
  public static let functionCodeType1: UInt8 = 0xF2
  public static let functionCodeType2: UInt8 = 0xFC
  public static let inquiryType1: UInt8 = 0x02
  public static let inquiryType2: UInt8 = 0x0C

  /// The inquiry byte to use, chosen from what the device declared rather than fixed to
  /// one model. A device that declares neither function has no speak-to-chat.
  public static func inquiry(forDeclared functions: Set<UInt8>) -> UInt8? {
    if functions.contains(functionCodeType2) { return inquiryType2 }
    if functions.contains(functionCodeType1) { return inquiryType1 }
    return nil
  }

  private static let getCapability: UInt8 = 0xF0
  private static let returnCapability: UInt8 = 0xF1
  private static let getStatus: UInt8 = 0xF2
  private static let returnStatus: UInt8 = 0xF3
  private static let notifyStatus: UInt8 = 0xF5
  private static let getParameter: UInt8 = 0xF6
  private static let returnParameter: UInt8 = 0xF7
  private static let setParameter: UInt8 = 0xF8
  private static let notifyParameter: UInt8 = 0xF9
  private static let getExtendedParameter: UInt8 = 0xFA
  private static let returnExtendedParameter: UInt8 = 0xFB
  private static let setExtendedParameter: UInt8 = 0xFC
  private static let notifyExtendedParameter: UInt8 = 0xFD

  public static func capabilityRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getCapability, inquiry])
  }

  public static func statusRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getStatus, inquiry])
  }

  public static func parameterRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getParameter, inquiry])
  }

  public static func extendedParameterRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getExtendedParameter, inquiry])
  }

  public static func setEnabledRequest(
    sequence: UInt8,
    inquiry: UInt8,
    isEnabled: Bool,
    secondarySettingEnabled: Bool
  ) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [
        setParameter,
        inquiry,
        onOff(isEnabled),
        onOff(secondarySettingEnabled),
      ]
    )
  }

  public static func setDetailRequest(
    sequence: UInt8,
    inquiry: UInt8,
    sensitivity: TandemSpeakToChatSensitivity,
    timeout: TandemSpeakToChatTimeout
  ) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [setExtendedParameter, inquiry, sensitivity.rawValue, timeout.rawValue]
    )
  }

  public static func parseCapabilityResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> TandemSpeakToChatCapability {
    let bytes = try bytes(frame, command: returnCapability, inquiry: inquiry)
    guard bytes.count == 6 else { throw TandemSpeakToChatError.invalidLength(bytes.count) }
    guard bytes[2] == 0 || bytes[2] == 1 else {
      throw TandemSpeakToChatError.invalidPreview(bytes[2])
    }
    return TandemSpeakToChatCapability(
      supportsPreview: bytes[2] == 1,
      fastSeconds: Int(bytes[3]),
      mediumSeconds: Int(bytes[4]),
      slowSeconds: Int(bytes[5])
    )
  }

  public static func parseStatusResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (isControlEnabled: Bool, effectStatus: TandemSpeakToChatEffectStatus) {
    try parseStatus(frame, command: returnStatus, inquiry: inquiry)
  }

  public static func parseStatusNotification(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (isControlEnabled: Bool, effectStatus: TandemSpeakToChatEffectStatus) {
    try parseStatus(frame, command: notifyStatus, inquiry: inquiry)
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (isEnabled: Bool, secondarySettingEnabled: Bool) {
    try parseParameters(frame, command: returnParameter, inquiry: inquiry)
  }

  public static func parseParameterNotification(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (isEnabled: Bool, secondarySettingEnabled: Bool) {
    try parseParameters(frame, command: notifyParameter, inquiry: inquiry)
  }

  public static func parseExtendedParameterResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (sensitivity: TandemSpeakToChatSensitivity, timeout: TandemSpeakToChatTimeout) {
    try parseDetail(frame, command: returnExtendedParameter, inquiry: inquiry)
  }

  public static func parseExtendedParameterNotification(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> (sensitivity: TandemSpeakToChatSensitivity, timeout: TandemSpeakToChatTimeout) {
    try parseDetail(frame, command: notifyExtendedParameter, inquiry: inquiry)
  }

  private static func parseStatus(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8
  ) throws -> (isControlEnabled: Bool, effectStatus: TandemSpeakToChatEffectStatus) {
    let bytes = try bytes(frame, command: command, inquiry: inquiry)
    guard bytes.count == 4 else { throw TandemSpeakToChatError.invalidLength(bytes.count) }
    guard bytes[2] == 0 || bytes[2] == 1 else {
      throw TandemSpeakToChatError.invalidEnableDisable(bytes[2])
    }
    guard let effect = TandemSpeakToChatEffectStatus(rawValue: bytes[3]) else {
      throw TandemSpeakToChatError.invalidEffectStatus(bytes[3])
    }
    return (bytes[2] == 0, effect)
  }

  private static func parseParameters(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8
  ) throws -> (isEnabled: Bool, secondarySettingEnabled: Bool) {
    let bytes = try bytes(frame, command: command, inquiry: inquiry)
    guard bytes.count == 4 else { throw TandemSpeakToChatError.invalidLength(bytes.count) }
    guard bytes[2] == 0 || bytes[2] == 1 else {
      throw TandemSpeakToChatError.invalidOnOff(bytes[2])
    }
    guard bytes[3] == 0 || bytes[3] == 1 else {
      throw TandemSpeakToChatError.invalidOnOff(bytes[3])
    }
    return (bytes[2] == 0, bytes[3] == 0)
  }

  private static func parseDetail(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8
  ) throws -> (sensitivity: TandemSpeakToChatSensitivity, timeout: TandemSpeakToChatTimeout) {
    let bytes = try bytes(frame, command: command, inquiry: inquiry)
    guard bytes.count == 4 else { throw TandemSpeakToChatError.invalidLength(bytes.count) }
    guard let sensitivity = TandemSpeakToChatSensitivity(rawValue: bytes[2]) else {
      throw TandemSpeakToChatError.invalidSensitivity(bytes[2])
    }
    guard let timeout = TandemSpeakToChatTimeout(rawValue: bytes[3]) else {
      throw TandemSpeakToChatError.invalidTimeout(bytes[3])
    }
    return (sensitivity, timeout)
  }

  private static func request(sequence: UInt8, payload: [UInt8]) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: sequence,
      payload: Data(payload)
    )
  }

  private static func bytes(_ frame: TandemFrame, command: UInt8, inquiry: UInt8) throws -> [UInt8] {
    guard frame.dataType == TandemFrame.table1DataType else {
      throw TandemSpeakToChatError.unexpectedDataType(frame.dataType)
    }
    let bytes = [UInt8](frame.payload)
    let expected = [command, inquiry]
    guard bytes.count >= 2, Array(bytes.prefix(2)) == expected else {
      throw TandemSpeakToChatError.unexpectedPayload(
        expected: expected,
        actual: Array(bytes.prefix(2))
      )
    }
    return bytes
  }

  private static func onOff(_ isOn: Bool) -> UInt8 { isOn ? 0x00 : 0x01 }
}
