import Foundation

public struct TandemEqualizerPreset: Equatable, Sendable {
  public let identifier: UInt8
  public let name: String

  public init(identifier: UInt8, name: String) {
    self.identifier = identifier
    self.name = name
  }
}

public struct TandemEqualizerCapability: Equatable, Sendable {
  public let bandCount: Int
  public let levelStepCount: Int
  public let presets: [TandemEqualizerPreset]

  public init(
    bandCount: Int,
    levelStepCount: Int,
    presets: [TandemEqualizerPreset]
  ) {
    self.bandCount = bandCount
    self.levelStepCount = levelStepCount
    self.presets = presets
  }
}

public struct TandemEqualizerStatus: Equatable, Sendable {
  public let isEnabled: Bool
  public let errorCodes: [UInt8]

  public init(isEnabled: Bool, errorCodes: [UInt8]) {
    self.isEnabled = isEnabled
    self.errorCodes = errorCodes
  }
}

public struct TandemEqualizerParameters: Equatable, Sendable {
  public let presetIdentifier: UInt8
  public let bandSteps: [UInt8]

  public init(presetIdentifier: UInt8, bandSteps: [UInt8]) {
    self.presetIdentifier = presetIdentifier
    self.bandSteps = bandSteps
  }
}

public struct TandemEqualizerBand: Equatable, Sendable {
  public let informationType: UInt8
  public let value: UInt16

  public init(informationType: UInt8, value: UInt16) {
    self.informationType = informationType
    self.value = value
  }
}

public struct TandemEqualizerSnapshot: Equatable, Sendable {
  public let capability: TandemEqualizerCapability
  public let status: TandemEqualizerStatus
  public let parameters: TandemEqualizerParameters
  public let bands: [TandemEqualizerBand]

  public init(
    capability: TandemEqualizerCapability,
    status: TandemEqualizerStatus,
    parameters: TandemEqualizerParameters,
    bands: [TandemEqualizerBand]
  ) {
    self.capability = capability
    self.status = status
    self.parameters = parameters
    self.bands = bands
  }

  public var presetName: String? {
    capability.presets.first(where: { $0.identifier == parameters.presetIdentifier })?.name
  }

  public var gainValues: [Int]? {
    guard capability.levelStepCount > 0, capability.levelStepCount.isMultiple(of: 2) == false else {
      return nil
    }
    let neutralStep = (capability.levelStepCount - 1) / 2
    return parameters.bandSteps.map { Int($0) - neutralStep }
  }
}

public enum TandemEqualizerError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedPayload(expected: [UInt8], actual: [UInt8])
  case invalidCapabilityLength(Int)
  case invalidPresetEntry(Int)
  case invalidPresetName(Int)
  case presetCountMismatch(expected: Int, actual: Int)
  case invalidStatusLength(expected: Int, actual: Int)
  case invalidEnableDisable(UInt8)
  case invalidParameterLength(expected: Int, actual: Int)
  case invalidExtendedInfoLength(expected: Int, actual: Int)
  case bandCountMismatch(expected: Int, actual: Int)
  case bandStepOutOfRange(step: UInt8, levelStepCount: Int)

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      String(format: "unexpected Tandem data type 0x%02X", value)
    case .unexpectedPayload(let expected, let actual):
      "unexpected payload prefix \(actual); expected \(expected)"
    case .invalidCapabilityLength(let length):
      "invalid equalizer capability length \(length)"
    case .invalidPresetEntry(let offset):
      "invalid equalizer preset entry at offset \(offset)"
    case .invalidPresetName(let identifier):
      String(format: "invalid UTF-8 preset name for 0x%02X", identifier)
    case .presetCountMismatch(let expected, let actual):
      "equalizer preset count mismatch: expected \(expected), actual \(actual)"
    case .invalidStatusLength(let expected, let actual):
      "equalizer status length mismatch: expected \(expected), actual \(actual)"
    case .invalidEnableDisable(let value):
      "invalid equalizer enable/disable value \(value)"
    case .invalidParameterLength(let expected, let actual):
      "equalizer parameter length mismatch: expected \(expected), actual \(actual)"
    case .invalidExtendedInfoLength(let expected, let actual):
      "equalizer extended-info length mismatch: expected \(expected), actual \(actual)"
    case .bandCountMismatch(let expected, let actual):
      "equalizer band count mismatch: expected \(expected), actual \(actual)"
    case .bandStepOutOfRange(let step, let levelStepCount):
      "equalizer band step \(step) is outside 0..<\(levelStepCount)"
    }
  }
}

public enum TandemReadOnlyEqualizer {
  public static let presetEqualizerWithErrorCodeInquiry: UInt8 = 0x04

  private static let getCapability: UInt8 = 0x50
  private static let returnCapability: UInt8 = 0x51
  private static let getStatus: UInt8 = 0x52
  private static let returnStatus: UInt8 = 0x53
  private static let getParameter: UInt8 = 0x56
  private static let returnParameter: UInt8 = 0x57
  private static let setParameter: UInt8 = 0x58
  private static let notifyParameter: UInt8 = 0x59
  private static let getExtendedInfo: UInt8 = 0x5A
  private static let returnExtendedInfo: UInt8 = 0x5B
  private static let japaneseDisplayLanguage: UInt8 = 0x0B

  public static func capabilityRequest(sequence: UInt8) throws -> TandemFrame {
    return try request(
      sequence: sequence,
      payload: [
        getCapability,
        presetEqualizerWithErrorCodeInquiry,
        japaneseDisplayLanguage,
      ]
    )
  }

  public static func statusRequest(sequence: UInt8) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [getStatus, presetEqualizerWithErrorCodeInquiry]
    )
  }

  /// The older generation asks with its own inquiry byte; everything else about the
  /// parameter conversation is the same shape.
  public static let legacyInquiry: UInt8 = 0x01

  public static func inquiry(for dialect: TandemDialect) -> UInt8 {
    dialect == .legacy ? legacyInquiry : presetEqualizerWithErrorCodeInquiry
  }

  public static func parameterRequest(
    sequence: UInt8,
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry
  ) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [getParameter, inquiry]
    )
  }

  public static func extendedInfoRequest(sequence: UInt8) throws -> TandemFrame {
    try request(
      sequence: sequence,
      payload: [getExtendedInfo, presetEqualizerWithErrorCodeInquiry]
    )
  }

  /// Builds a preset selection (empty `bandSteps`) or a band-level write.
  ///
  /// When the device's declared `capability` is passed, the write is checked
  /// against it before anything reaches the wire: a band count or step the device
  /// never declared is a caller bug, and refusing it here is cheaper than having
  /// the device ignore or misapply the frame. The parameter is optional so
  /// existing call sites keep compiling; new callers should pass it.
  public static func setParameterRequest(
    sequence: UInt8,
    presetIdentifier: UInt8,
    bandSteps: [UInt8],
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry,
    capability: TandemEqualizerCapability? = nil
  ) throws -> TandemFrame {
    guard bandSteps.count <= Int(UInt8.max) else {
      throw TandemEqualizerError.invalidParameterLength(
        expected: Int(UInt8.max),
        actual: bandSteps.count
      )
    }
    if let capability {
      if !bandSteps.isEmpty, bandSteps.count != capability.bandCount {
        throw TandemEqualizerError.bandCountMismatch(
          expected: capability.bandCount,
          actual: bandSteps.count
        )
      }
      if capability.levelStepCount > 0 {
        for step in bandSteps where Int(step) >= capability.levelStepCount {
          throw TandemEqualizerError.bandStepOutOfRange(
            step: step,
            levelStepCount: capability.levelStepCount
          )
        }
      }
    }
    return try request(
      sequence: sequence,
      payload: [
        setParameter,
        inquiry,
        presetIdentifier,
        UInt8(bandSteps.count),
      ] + bandSteps
    )
  }

  public static func parseCapabilityResponse(
    _ frame: TandemFrame
  ) throws -> TandemEqualizerCapability {
    try requireTable1(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnCapability)
    guard bytes.count >= 5 else {
      throw TandemEqualizerError.invalidCapabilityLength(bytes.count)
    }

    let bandCount = Int(bytes[2])
    let levelStepCount = Int(bytes[3])
    let expectedPresetCount = Int(bytes[4])
    var presets: [TandemEqualizerPreset] = []
    var offset = 5
    while offset < bytes.count {
      guard offset + 2 <= bytes.count else {
        throw TandemEqualizerError.invalidPresetEntry(offset)
      }
      let identifier = bytes[offset]
      let nameLength = Int(bytes[offset + 1])
      let nameStart = offset + 2
      let nameEnd = nameStart + nameLength
      guard nameEnd <= bytes.count else {
        throw TandemEqualizerError.invalidPresetEntry(offset)
      }
      let nameData = Data(bytes[nameStart..<nameEnd])
      guard let name = String(data: nameData, encoding: .utf8) else {
        throw TandemEqualizerError.invalidPresetName(Int(identifier))
      }
      presets.append(TandemEqualizerPreset(identifier: identifier, name: name))
      offset = nameEnd
    }

    guard presets.count == expectedPresetCount else {
      throw TandemEqualizerError.presetCountMismatch(
        expected: expectedPresetCount,
        actual: presets.count
      )
    }
    return TandemEqualizerCapability(
      bandCount: bandCount,
      levelStepCount: levelStepCount,
      presets: presets
    )
  }

  public static func parseStatusResponse(
    _ frame: TandemFrame
  ) throws -> TandemEqualizerStatus {
    try requireTable1(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnStatus)
    guard bytes.count >= 4 else {
      throw TandemEqualizerError.invalidStatusLength(expected: 4, actual: bytes.count)
    }
    let errorCount = Int(bytes[3])
    let expectedLength = 4 + errorCount
    guard bytes.count == expectedLength else {
      throw TandemEqualizerError.invalidStatusLength(
        expected: expectedLength,
        actual: bytes.count
      )
    }
    guard bytes[2] == 0 || bytes[2] == 1 else {
      throw TandemEqualizerError.invalidEnableDisable(bytes[2])
    }
    return TandemEqualizerStatus(
      isEnabled: bytes[2] == 0,
      errorCodes: Array(bytes.dropFirst(4))
    )
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    capability: TandemEqualizerCapability,
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry
  ) throws -> TandemEqualizerParameters {
    try requireTable1(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnParameter, inquiry: inquiry)
    guard bytes.count >= 4 else {
      throw TandemEqualizerError.invalidParameterLength(expected: 4, actual: bytes.count)
    }
    let actualBandCount = Int(bytes[3])
    guard actualBandCount == capability.bandCount else {
      throw TandemEqualizerError.bandCountMismatch(
        expected: capability.bandCount,
        actual: actualBandCount
      )
    }
    let expectedLength = 4 + actualBandCount
    guard bytes.count == expectedLength else {
      throw TandemEqualizerError.invalidParameterLength(
        expected: expectedLength,
        actual: bytes.count
      )
    }
    let steps = Array(bytes.dropFirst(4))
    if capability.levelStepCount > 0 {
      for step in steps where Int(step) >= capability.levelStepCount {
        throw TandemEqualizerError.bandStepOutOfRange(
          step: step,
          levelStepCount: capability.levelStepCount
        )
      }
    }
    return TandemEqualizerParameters(
      presetIdentifier: bytes[2],
      bandSteps: steps
    )
  }

  /// Parses the device-initiated parameter notification. The older generation
  /// notifies with its own inquiry byte just as it answers with one, so the
  /// inquiry is a parameter here too; the default keeps current-generation call
  /// sites unchanged.
  public static func parseParameterNotification(
    _ frame: TandemFrame,
    capability: TandemEqualizerCapability,
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry
  ) throws -> TandemEqualizerParameters {
    try parseParameters(
      frame,
      expectedCommand: notifyParameter,
      capability: capability,
      allowsEmptyBands: true,
      inquiry: inquiry
    )
  }

  public static func parseExtendedInfoResponse(
    _ frame: TandemFrame,
    capability: TandemEqualizerCapability
  ) throws -> [TandemEqualizerBand] {
    try requireTable1(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnExtendedInfo)
    guard bytes.count >= 3 else {
      throw TandemEqualizerError.invalidExtendedInfoLength(expected: 3, actual: bytes.count)
    }
    let actualBandCount = Int(bytes[2])
    guard actualBandCount == capability.bandCount else {
      throw TandemEqualizerError.bandCountMismatch(
        expected: capability.bandCount,
        actual: actualBandCount
      )
    }
    let expectedLength = 3 + (actualBandCount * 3)
    guard bytes.count == expectedLength else {
      throw TandemEqualizerError.invalidExtendedInfoLength(
        expected: expectedLength,
        actual: bytes.count
      )
    }
    return (0..<actualBandCount).map { index in
      let offset = 3 + (index * 3)
      return TandemEqualizerBand(
        informationType: bytes[offset],
        value: (UInt16(bytes[offset + 1]) << 8) | UInt16(bytes[offset + 2])
      )
    }
  }

  private static func request(sequence: UInt8, payload: [UInt8]) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: sequence,
      payload: Data(payload)
    )
  }

  private static func parseParameters(
    _ frame: TandemFrame,
    expectedCommand: UInt8,
    capability: TandemEqualizerCapability,
    allowsEmptyBands: Bool,
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry
  ) throws -> TandemEqualizerParameters {
    try requireTable1(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: expectedCommand, inquiry: inquiry)
    guard bytes.count >= 4 else {
      throw TandemEqualizerError.invalidParameterLength(expected: 4, actual: bytes.count)
    }
    let actualBandCount = Int(bytes[3])
    guard
      actualBandCount == capability.bandCount
        || (allowsEmptyBands && actualBandCount == 0)
    else {
      throw TandemEqualizerError.bandCountMismatch(
        expected: capability.bandCount,
        actual: actualBandCount
      )
    }
    let expectedLength = 4 + actualBandCount
    guard bytes.count == expectedLength else {
      throw TandemEqualizerError.invalidParameterLength(
        expected: expectedLength,
        actual: bytes.count
      )
    }
    let steps = Array(bytes.dropFirst(4))
    if capability.levelStepCount > 0 {
      for step in steps where Int(step) >= capability.levelStepCount {
        throw TandemEqualizerError.bandStepOutOfRange(
          step: step,
          levelStepCount: capability.levelStepCount
        )
      }
    }
    return TandemEqualizerParameters(
      presetIdentifier: bytes[2],
      bandSteps: steps
    )
  }

  private static func requireTable1(_ frame: TandemFrame) throws {
    guard frame.dataType == TandemFrame.table1DataType else {
      throw TandemEqualizerError.unexpectedDataType(frame.dataType)
    }
  }

  private static func requirePrefix(
    _ bytes: [UInt8],
    command: UInt8,
    inquiry: UInt8 = presetEqualizerWithErrorCodeInquiry
  ) throws {
    let expected = [command, inquiry]
    guard bytes.count >= 2, Array(bytes.prefix(2)) == expected else {
      throw TandemEqualizerError.unexpectedPayload(
        expected: expected,
        actual: Array(bytes.prefix(2))
      )
    }
  }
}
