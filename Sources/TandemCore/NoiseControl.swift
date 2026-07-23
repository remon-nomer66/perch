import Foundation

/// Which shape of noise-control conversation a device speaks.
///
/// A device declares one of a family of function codes, and each maps to the inquiry
/// byte its answers are keyed by. The mapping is what makes this work on a model
/// nobody has tested: the device says which dialect it uses, and we follow.
///
/// Taken from the protocol documentation of `andreabedini/soundconnectd`; see
/// `THIRD_PARTY_NOTICES.md`. The byte layout of the parameter payload was validated
/// against WF-1000XM6 hardware, which is why `mode` at `[4]` is trusted over the
/// documentation's example for a different type.
public enum TandemNoiseControlType {
  /// Function codes in declaration order of preference: the richer variants come
  /// first, so a device advertising several is driven by the most capable one.
  private static let mapping: [(function: UInt8, inquiry: UInt8)] = [
    (0x6D, 0x19),  // mode select with noise adaptation
    (0x6C, 0x18),  // with test mode
    (0x6B, 0x17),  // mode select, dual
    (0x6A, 0x16),  // mode select, dual/single
    (0x68, 0x15),  // mode select, dual/auto
    (0x69, 0x30),  // ambient sound control mode select
    (0x65, 0x14),  // dual/single off, ambient level
    (0x64, 0x13),  // on/off, ambient level
    (0x67, 0x22),  // ambient only, level
    (0x63, 0x12),  // dual/single off, ambient on/off
    (0x62, 0x11),  // on/off, ambient on/off
    (0x66, 0x21),  // ambient only, on/off
    (0x61, 0x01),  // noise cancelling on/off
  ]

  /// The inquiry byte to use, given what the device declared.
  public static func inquiry(forDeclared functions: Set<UInt8>) -> UInt8? {
    mapping.first { functions.contains($0.function) }?.inquiry
  }

  /// Types that carry a selectable mode and an adjustable ambient level. 0x02 is the
  /// older generation's one and only noise-control type.
  public static func hasAdjustableLevel(_ inquiry: UInt8) -> Bool {
    [0x02, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x22, 0x30].contains(inquiry)
  }

  /// Types that also report a noise-adaptation on/off and sensitivity.
  public static func hasNoiseAdaptation(_ inquiry: UInt8) -> Bool {
    [0x18, 0x19].contains(inquiry)
  }

  /// The ambient-only dialects: they offer outside sound and off, but no noise
  /// cancelling. Showing a noise-cancelling control for these would send a mode the
  /// function does not define.
  private static let ambientOnly: Set<UInt8> = [0x21, 0x22]
  /// The on/off dialect that only toggles noise cancelling, with no ambient sound.
  private static let noiseCancellingOnly: Set<UInt8> = [0x01]

  public static func hasNoiseCancelling(_ inquiry: UInt8) -> Bool {
    !ambientOnly.contains(inquiry)
  }

  public static func hasAmbient(_ inquiry: UInt8) -> Bool {
    !noiseCancellingOnly.contains(inquiry)
  }
}

/// One ambient sound mode the device offers, with the range it accepts.
public struct TandemAmbientModeCapability: Equatable, Sendable {
  /// 0 is the plain ambient mode; 1 is the one that emphasises voices.
  public let mode: UInt8
  public let minimumLevel: Int
  public let maximumLevel: Int
  public let step: Int

  public init(mode: UInt8, minimumLevel: Int, maximumLevel: Int, step: Int) {
    self.mode = mode
    self.minimumLevel = minimumLevel
    self.maximumLevel = maximumLevel
    self.step = step
  }

  public var range: ClosedRange<Int> {
    minimumLevel...max(maximumLevel, minimumLevel)
  }
}

public struct TandemNoiseControlState: Equatable, Sendable {
  /// False means both noise cancelling and ambient sound are off.
  public let isActive: Bool
  public let isNoiseCancelling: Bool
  public let ambientMode: UInt8
  public let ambientLevel: Int
  /// Present only on types that report it; `nil` elsewhere so a value is never
  /// invented for a device that does not have the feature.
  public let noiseAdaptation: NoiseAdaptation?

  public struct NoiseAdaptation: Equatable, Sendable {
    public let isOn: Bool
    public let sensitivity: UInt8

    public init(isOn: Bool, sensitivity: UInt8) {
      self.isOn = isOn
      self.sensitivity = sensitivity
    }
  }

  public init(
    isActive: Bool,
    isNoiseCancelling: Bool,
    ambientMode: UInt8,
    ambientLevel: Int,
    noiseAdaptation: NoiseAdaptation? = nil
  ) {
    self.isActive = isActive
    self.isNoiseCancelling = isNoiseCancelling
    self.ambientMode = ambientMode
    self.ambientLevel = ambientLevel
    self.noiseAdaptation = noiseAdaptation
  }
}

public enum TandemNoiseControlError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedCommand(UInt8)
  case unexpectedInquiry(UInt8)
  case truncated(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      return String(format: "予期しないdata type 0x%02Xです", value)
    case .unexpectedCommand(let value):
      return String(format: "予期しないcommand 0x%02Xです", value)
    case .unexpectedInquiry(let value):
      return String(format: "予期しないinquiry 0x%02Xです", value)
    case .truncated(let expected, let actual):
      return "応答が短すぎます（最低 \(expected) バイト、実際 \(actual) バイト）"
    }
  }
}

public enum TandemNoiseControlProtocol {
  private static let getCapability: UInt8 = 0x60
  private static let returnCapability: UInt8 = 0x61
  private static let getParameter: UInt8 = 0x66
  private static let returnParameter: UInt8 = 0x67
  private static let setParameter: UInt8 = 0x68
  private static let notifyParameter: UInt8 = 0x69

  // Byte offsets within the parameter payload, past command and inquiry.
  //
  // Validated against WF-1000XM6: `mode` at [4] is 0 for noise cancelling and 1 for
  // ambient sound. Reading it as a plain "noise cancelling" boolean inverts it, and
  // because the same inversion would sit in both read and write, the read-back check
  // could not catch the mistake — the device would do the opposite of the label while
  // the two sides quietly agreed with each other.
  private enum Offset {
    static let changeStatus = 2
    static let effectOn = 3
    static let mode = 4
    static let ambientMode = 5
    static let ambientLevel = 6
    static let adaptationOn = 7
    static let adaptationSensitivity = 8
  }

  private static let modeNoiseCancelling: UInt8 = 0
  private static let modeAmbientSound: UInt8 = 1

  // MARK: - The older generation

  /// The older generation speaks the same command family with one fixed type byte
  /// and its own payload layout: [enabled, wind, submode, 0x01, voice, level], with
  /// submode 1 meaning noise cancelling — the reverse of the newer layout's mode
  /// byte. Layout from the Gadgetbridge v1 implementation, validated on WF-1000XM3.
  public static let legacyInquiry: UInt8 = 0x02

  /// What the older generation offers, which it does not announce: plain and
  /// voice-focused ambient sound, level 1 to 20. Fixed by the generation, not by any
  /// model.
  public static let legacyAmbientModes: [TandemAmbientModeCapability] = [
    TandemAmbientModeCapability(mode: 0, minimumLevel: 1, maximumLevel: 20, step: 1),
    TandemAmbientModeCapability(mode: 1, minimumLevel: 1, maximumLevel: 20, step: 1),
  ]

  public static func capabilityRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getCapability, inquiry])
  }

  public static func parameterRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getParameter, inquiry])
  }

  /// `isFinal` distinguishes a value still being dragged from one the listener has
  /// settled on. Sending every intermediate position as final makes the headset
  /// re-apply the effect on each step.
  /// `valueFieldCount` is how many bytes the device's own parameter response carried
  /// after the command and inquiry. Passing it trims the request to the same shape, so
  /// a simpler dialect — say one that stops after the on/off flag — is never handed the
  /// mode, ambient, or level fields it does not define. Left `nil`, every applicable
  /// field is sent, which is right only when the device's layout is already known to be
  /// the full one.
  public static func setParameterRequest(
    sequence: UInt8,
    inquiry: UInt8,
    state: TandemNoiseControlState,
    isFinal: Bool = true,
    valueFieldCount: Int? = nil,
    legacyWindKind: UInt8 = 0
  ) throws -> TandemFrame {
    if inquiry == legacyInquiry {
      // The older layout has no change-status field, so isFinal has nothing to say.
      // The wind byte is echoed from what the device reported: under the wind-capable
      // layout the noise-cancelling submode is 2 where the plain layout uses 1, and
      // the level is zeroed for noise cancelling the way the device itself reports it.
      let noiseSubmode: UInt8 = legacyWindKind == 2 ? 2 : 1
      let noiseCancelling = state.isActive && state.isNoiseCancelling
      return try request(
        sequence: sequence,
        payload: [
          setParameter,
          legacyInquiry,
          state.isActive ? 0x11 : 0x00,
          legacyWindKind,
          noiseCancelling ? noiseSubmode : 0x00,
          0x01,
          state.ambientMode,
          noiseCancelling ? 0x00 : UInt8(clamping: state.ambientLevel),
        ]
      )
    }
    var fields: [UInt8] = [
      isFinal ? 0x01 : 0x00,
      state.isActive ? 0x01 : 0x00,
      state.isNoiseCancelling ? modeNoiseCancelling : modeAmbientSound,
      state.ambientMode,
      UInt8(clamping: state.ambientLevel),
    ]
    // Only append noise-adaptation bytes for the types that carry them, and only when
    // the device gave us a value to echo back.
    if TandemNoiseControlType.hasNoiseAdaptation(inquiry), let adaptation = state.noiseAdaptation {
      fields.append(adaptation.isOn ? 0x01 : 0x00)
      fields.append(adaptation.sensitivity)
    }
    if let valueFieldCount {
      // Never send more than the device sent us; keep at least the change-status and
      // on/off flags every dialect has.
      fields = Array(fields.prefix(max(valueFieldCount, 2)))
    }
    return try request(sequence: sequence, payload: [setParameter, inquiry] + fields)
  }

  public static func parseCapabilityResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> [TandemAmbientModeCapability] {
    let bytes = try payload(frame, command: returnCapability, inquiry: inquiry, minimum: 3)
    let count = Int(bytes[2])
    var modes: [TandemAmbientModeCapability] = []
    modes.reserveCapacity(count)

    for index in 0..<count {
      let start = 3 + index * 4
      guard bytes.count >= start + 4 else {
        throw TandemNoiseControlError.truncated(expected: start + 4, actual: bytes.count)
      }
      modes.append(
        TandemAmbientModeCapability(
          mode: bytes[start],
          minimumLevel: Int(bytes[start + 1]),
          maximumLevel: Int(bytes[start + 2]),
          step: max(Int(bytes[start + 3]), 1)
        )
      )
    }
    return modes
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> TandemNoiseControlState {
    try parseParameter(frame, command: returnParameter, inquiry: inquiry)
  }

  public static func parseParameterNotification(
    _ frame: TandemFrame,
    inquiry: UInt8
  ) throws -> TandemNoiseControlState {
    try parseParameter(frame, command: notifyParameter, inquiry: inquiry)
  }

  // MARK: - Private

  private static func parseParameter(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8
  ) throws -> TandemNoiseControlState {
    if inquiry == legacyInquiry {
      let bytes = try payload(frame, command: command, inquiry: inquiry, minimum: 8)
      // Under the wind-capable layout (wind byte 2) the noise-cancelling submode is
      // 2; under the plain layout it is 1.
      let noiseSubmode: UInt8 = bytes[3] == 2 ? 2 : 1
      return TandemNoiseControlState(
        isActive: bytes[2] != 0,
        isNoiseCancelling: bytes[4] == noiseSubmode,
        ambientMode: bytes[6],
        ambientLevel: Int(bytes[7])
      )
    }
    let bytes = try payload(frame, command: command, inquiry: inquiry, minimum: Offset.effectOn + 1)

    // Simpler variants stop after the overall state; richer fields are read only when
    // present, so one layout serves every dialect without inventing values.
    let mode = bytes.count > Offset.mode ? bytes[Offset.mode] : modeNoiseCancelling
    let adaptation: TandemNoiseControlState.NoiseAdaptation?
    if bytes.count > Offset.adaptationSensitivity {
      adaptation = .init(
        isOn: bytes[Offset.adaptationOn] != 0,
        sensitivity: bytes[Offset.adaptationSensitivity]
      )
    } else {
      adaptation = nil
    }

    return TandemNoiseControlState(
      isActive: bytes[Offset.effectOn] != 0,
      isNoiseCancelling: mode == modeNoiseCancelling,
      ambientMode: bytes.count > Offset.ambientMode ? bytes[Offset.ambientMode] : 0,
      ambientLevel: bytes.count > Offset.ambientLevel ? Int(bytes[Offset.ambientLevel]) : 0,
      noiseAdaptation: adaptation
    )
  }

  private static func payload(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8,
    minimum: Int
  ) throws -> [UInt8] {
    guard frame.dataType == TandemFrame.table1DataType else {
      throw TandemNoiseControlError.unexpectedDataType(frame.dataType)
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= minimum else {
      throw TandemNoiseControlError.truncated(expected: minimum, actual: bytes.count)
    }
    guard bytes[0] == command else {
      throw TandemNoiseControlError.unexpectedCommand(bytes[0])
    }
    guard bytes[1] == inquiry else {
      throw TandemNoiseControlError.unexpectedInquiry(bytes[1])
    }
    return bytes
  }

  private static func request(sequence: UInt8, payload: [UInt8]) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table1DataType,
      sequence: sequence,
      payload: Data(payload)
    )
  }
}
