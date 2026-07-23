import Foundation

/// The room size a background-music listening mode simulates.
///
/// The values come from the device's `BGM_MODE_SMALL_MIDDLE_LARGE` function; the
/// names follow it rather than a specific model's app wording.
public enum TandemListeningRoom: UInt8, CaseIterable, Hashable, Sendable {
  case small = 0
  case middle = 1
  case large = 2
}

/// The kinds of listening mode this app knows how to drive.
///
/// A device exposes each as a separate on/off function; the Sony app presents them
/// together as one "Listening Mode" picker whose Standard entry is every kind off.
public enum TandemListeningKind: Equatable, Hashable, Sendable {
  /// Background music with a room size. Function `BGM_MODE_*`.
  case backgroundMusic
  /// Cinema upmix, a plain on/off. Function `UPMIX_CINEMA`.
  case cinema
}

/// A listening feature the device declared, tied to the inquiry byte its messages
/// are keyed by.
///
/// The function→inquiry pairing is a protocol constant, not a per-model value, so it
/// is only ever used for a device that declared the function. A model that declares
/// none gets no listening controls and is never sent a listening message.
public struct TandemListeningFeature: Equatable, Hashable, Sendable, Identifiable {
  public let function: UInt8
  public let inquiry: UInt8
  public let kind: TandemListeningKind

  public var id: UInt8 { function }

  public init(function: UInt8, inquiry: UInt8, kind: TandemListeningKind) {
    self.function = function
    self.inquiry = inquiry
    self.kind = kind
  }
}

public enum TandemListeningCatalog {
  /// Function code → (inquiry, kind), richer variants first so a device that declares
  /// several background-music variants is driven by the one that also reports errors.
  private static let entries: [TandemListeningFeature] = [
    .init(function: 0xEB, inquiry: 0x09, kind: .backgroundMusic),  // with error codes
    .init(function: 0xE4, inquiry: 0x03, kind: .backgroundMusic),
    .init(function: 0xE5, inquiry: 0x04, kind: .cinema),
  ]

  /// The listening features a device offers, at most one per kind, in picker order.
  public static func features(forDeclared functions: Set<UInt8>) -> [TandemListeningFeature] {
    var result: [TandemListeningFeature] = []
    for entry in entries where functions.contains(entry.function) {
      if !result.contains(where: { $0.kind == entry.kind }) { result.append(entry) }
    }
    return result
  }
}

/// Which listening mode is selected. Standard means every feature is off.
public enum TandemListeningSelection: Equatable, Hashable, Sendable {
  case standard
  case backgroundMusic(TandemListeningRoom)
  case cinema
}

/// A single feature's decoded parameter.
public struct TandemListeningFeatureState: Equatable, Sendable {
  public let isOn: Bool
  /// Present for background music only.
  public let room: TandemListeningRoom?

  public init(isOn: Bool, room: TandemListeningRoom?) {
    self.isOn = isOn
    self.room = room
  }
}

/// What the device currently reports for its listening features, resolved into a
/// single selection for the picker.
public struct TandemListeningReading: Equatable, Sendable {
  public let features: [TandemListeningFeature]
  public let selection: TandemListeningSelection
  /// The room to restore when background music is re-selected after Standard.
  public let savedRoom: TandemListeningRoom

  public init(
    features: [TandemListeningFeature],
    selection: TandemListeningSelection,
    savedRoom: TandemListeningRoom
  ) {
    self.features = features
    self.selection = selection
    self.savedRoom = savedRoom
  }

  public var hasBackgroundMusic: Bool { features.contains { $0.kind == .backgroundMusic } }
  public var hasCinema: Bool { features.contains { $0.kind == .cinema } }

  /// True when a non-standard mode is active. The device turns the equaliser off
  /// while one is, so the app disables the equaliser controls to match.
  public var disablesEqualizer: Bool { selection != .standard }

  public func feature(_ kind: TandemListeningKind) -> TandemListeningFeature? {
    features.first { $0.kind == kind }
  }

  /// Resolve per-feature states into one selection. Cinema wins if both report on,
  /// which only happens transiently while the device applies a switch.
  public static func resolve(
    features: [TandemListeningFeature],
    states: [UInt8: TandemListeningFeatureState]
  ) -> TandemListeningReading {
    let bgm = features.first { $0.kind == .backgroundMusic }.flatMap { states[$0.inquiry] }
    let cinema = features.first { $0.kind == .cinema }.flatMap { states[$0.inquiry] }
    let savedRoom = bgm?.room ?? .middle

    let selection: TandemListeningSelection
    if cinema?.isOn == true {
      selection = .cinema
    } else if bgm?.isOn == true {
      selection = .backgroundMusic(bgm?.room ?? savedRoom)
    } else {
      selection = .standard
    }
    return TandemListeningReading(features: features, selection: selection, savedRoom: savedRoom)
  }
}

public enum TandemListeningModeError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedCommand(UInt8)
  case unexpectedInquiry(UInt8)
  case truncated(expected: Int, actual: Int)
  case invalidRoom(UInt8)

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      String(format: "予期しないdata type 0x%02Xです", value)
    case .unexpectedCommand(let value):
      String(format: "予期しないcommand 0x%02Xです", value)
    case .unexpectedInquiry(let value):
      String(format: "予期しないinquiry 0x%02Xです", value)
    case .truncated(let expected, let actual):
      "応答が短すぎます（最低 \(expected) バイト、実際 \(actual) バイト）"
    case .invalidRoom(let value):
      String(format: "未知の部屋サイズ 0x%02Xです", value)
    }
  }
}

public enum TandemListeningModeProtocol {
  private static let getStatus: UInt8 = 0xE2
  private static let returnStatus: UInt8 = 0xE3
  private static let getParameter: UInt8 = 0xE6
  private static let returnParameter: UInt8 = 0xE7
  private static let setParameter: UInt8 = 0xE8

  /// The device encodes on with 0 and off (standard) with 1, the same as its
  /// background-music standard/background flag.
  private static let valueOn: UInt8 = 0x00
  private static let valueOff: UInt8 = 0x01

  public static func statusRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getStatus, inquiry])
  }

  public static func parameterRequest(sequence: UInt8, inquiry: UInt8) throws -> TandemFrame {
    try request(sequence: sequence, payload: [getParameter, inquiry])
  }

  /// Builds the write for a feature.
  ///
  /// Unlike noise control, no change-status ("final versus intermediate") byte has
  /// been observed in this message, so the encoding has nowhere to carry one.
  /// Whether a write is an intermediate step or the settled value is a send-policy
  /// decision — fire-and-forget versus read-back — that belongs to the caller.
  public static func setRequest(
    sequence: UInt8,
    feature: TandemListeningFeature,
    on: Bool,
    room: TandemListeningRoom
  ) throws -> TandemFrame {
    var payload: [UInt8] = [setParameter, feature.inquiry, on ? valueOn : valueOff]
    if feature.kind == .backgroundMusic { payload.append(room.rawValue) }
    return try request(sequence: sequence, payload: payload)
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    feature: TandemListeningFeature
  ) throws -> TandemListeningFeatureState {
    let bytes = try payload(frame, command: returnParameter, inquiry: feature.inquiry, minimum: 3)
    let isOn = bytes[2] == valueOn
    switch feature.kind {
    case .cinema:
      return TandemListeningFeatureState(isOn: isOn, room: nil)
    case .backgroundMusic:
      guard bytes.count > 3 else {
        throw TandemListeningModeError.truncated(expected: 4, actual: bytes.count)
      }
      guard let room = TandemListeningRoom(rawValue: bytes[3]) else {
        throw TandemListeningModeError.invalidRoom(bytes[3])
      }
      return TandemListeningFeatureState(isOn: isOn, room: room)
    }
  }

  // MARK: - Private

  private static func payload(
    _ frame: TandemFrame,
    command: UInt8,
    inquiry: UInt8,
    minimum: Int
  ) throws -> [UInt8] {
    guard frame.dataType == TandemFrame.table1DataType else {
      throw TandemListeningModeError.unexpectedDataType(frame.dataType)
    }
    let bytes = [UInt8](frame.payload)
    guard bytes.count >= minimum else {
      throw TandemListeningModeError.truncated(expected: minimum, actual: bytes.count)
    }
    guard bytes[0] == command else {
      throw TandemListeningModeError.unexpectedCommand(bytes[0])
    }
    guard bytes[1] == inquiry else {
      throw TandemListeningModeError.unexpectedInquiry(bytes[1])
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
