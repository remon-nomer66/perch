import Foundation

public enum TandemPeripheralBluetoothMode: UInt8, Equatable, Sendable {
  case normal = 0
  case inquiryScan = 1
}

public enum TandemMultipointInquiry: UInt8, Equatable, Sendable {
  case classic = 0x00
  case withBluetoothClassOfDevice = 0x02
}

public struct TandemMultipointDevice: Equatable, Sendable {
  public let address: String
  public let connectionIndex: Int
  public let name: String
  public let bluetoothClassOfDevice: Int?

  public init(
    address: String,
    connectionIndex: Int,
    name: String,
    bluetoothClassOfDevice: Int? = nil
  ) {
    self.address = address
    self.connectionIndex = connectionIndex
    self.name = name
    self.bluetoothClassOfDevice = bluetoothClassOfDevice
  }

  public var isConnected: Bool { connectionIndex > 0 }
}

public struct TandemMultipointSnapshot: Equatable, Sendable {
  public let bluetoothMode: TandemPeripheralBluetoothMode
  public let isControlEnabled: Bool
  public let devices: [TandemMultipointDevice]
  public let activeConnectionIndex: Int

  public init(
    bluetoothMode: TandemPeripheralBluetoothMode,
    isControlEnabled: Bool,
    devices: [TandemMultipointDevice],
    activeConnectionIndex: Int
  ) {
    self.bluetoothMode = bluetoothMode
    self.isControlEnabled = isControlEnabled
    self.devices = devices
    self.activeConnectionIndex = activeConnectionIndex
  }

  public var connectedDevices: [TandemMultipointDevice] {
    devices.filter(\.isConnected).sorted { $0.connectionIndex < $1.connectionIndex }
  }

  public var activeDevice: TandemMultipointDevice? {
    connectedDevices.first { $0.connectionIndex == activeConnectionIndex }
  }
}

public enum TandemMultipointError: Error, Equatable, CustomStringConvertible, Sendable {
  case unexpectedDataType(UInt8)
  case unexpectedPayload(expected: [UInt8], actual: [UInt8])
  case invalidStatusLength(Int)
  case invalidBluetoothMode(UInt8)
  case invalidEnableDisable(UInt8)
  case truncatedDevice(index: Int)
  case invalidAddress(index: Int)
  case invalidNameLength(index: Int, length: Int)
  case invalidName(index: Int)
  case trailingLength(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case .unexpectedDataType(let value):
      String(format: "unexpected Tandem data type 0x%02X", value)
    case .unexpectedPayload(let expected, let actual):
      "unexpected payload prefix \(actual); expected \(expected)"
    case .invalidStatusLength(let length):
      "invalid multipoint status length \(length)"
    case .invalidBluetoothMode(let value):
      "invalid peripheral Bluetooth mode \(value)"
    case .invalidEnableDisable(let value):
      "invalid enable/disable value \(value)"
    case .truncatedDevice(let index):
      "multipoint device \(index) is truncated"
    case .invalidAddress(let index):
      "multipoint device \(index) has an invalid address"
    case .invalidNameLength(let index, let length):
      "multipoint device \(index) has invalid name length \(length)"
    case .invalidName(let index):
      "multipoint device \(index) has an invalid UTF-8 name"
    case .trailingLength(let expected, let actual):
      "multipoint payload length mismatch: expected \(expected), actual \(actual)"
    }
  }
}

public enum TandemReadOnlyMultipoint {
  public static let pairingDeviceManagementFunctionCode: UInt8 = 0x30
  public static let pairingDeviceManagementWithClassFunctionCodes: Set<UInt8> = [0x32, 0x33]

  private static let getStatus: UInt8 = 0x32
  private static let returnStatus: UInt8 = 0x33
  private static let getParameter: UInt8 = 0x36
  private static let returnParameter: UInt8 = 0x37

  public static func statusRequest(
    sequence: UInt8,
    inquiry: TandemMultipointInquiry = .classic
  ) throws -> TandemFrame {
    try request(sequence: sequence, command: getStatus, inquiry: inquiry)
  }

  public static func parameterRequest(
    sequence: UInt8,
    inquiry: TandemMultipointInquiry = .classic
  ) throws -> TandemFrame {
    try request(sequence: sequence, command: getParameter, inquiry: inquiry)
  }

  public static func parseStatusResponse(
    _ frame: TandemFrame,
    inquiry: TandemMultipointInquiry = .classic
  ) throws -> (mode: TandemPeripheralBluetoothMode, isControlEnabled: Bool) {
    try requireTable2(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnStatus, inquiry: inquiry)
    guard bytes.count == 4 else {
      throw TandemMultipointError.invalidStatusLength(bytes.count)
    }
    guard let mode = TandemPeripheralBluetoothMode(rawValue: bytes[2]) else {
      throw TandemMultipointError.invalidBluetoothMode(bytes[2])
    }
    guard bytes[3] == 0 || bytes[3] == 1 else {
      throw TandemMultipointError.invalidEnableDisable(bytes[3])
    }
    return (mode, bytes[3] == 0)
  }

  public static func parseParameterResponse(
    _ frame: TandemFrame,
    bluetoothMode: TandemPeripheralBluetoothMode,
    isControlEnabled: Bool,
    inquiry: TandemMultipointInquiry = .classic
  ) throws -> TandemMultipointSnapshot {
    try requireTable2(frame)
    let bytes = [UInt8](frame.payload)
    try requirePrefix(bytes, command: returnParameter, inquiry: inquiry)
    guard bytes.count >= 4 else {
      throw TandemMultipointError.trailingLength(expected: 4, actual: bytes.count)
    }

    let deviceCount = Int(bytes[2])
    var offset = 3
    var devices: [TandemMultipointDevice] = []
    devices.reserveCapacity(deviceCount)

    for deviceIndex in 0..<deviceCount {
      let fixedLength = inquiry == .classic ? 19 : 22
      guard bytes.count >= offset + fixedLength else {
        throw TandemMultipointError.truncatedDevice(index: deviceIndex)
      }
      let nameLengthOffset =
        inquiry == .withBluetoothClassOfDevice ? offset + 21 : offset + 18
      let nameLength = Int(bytes[nameLengthOffset])
      guard nameLength <= 128 else {
        throw TandemMultipointError.invalidNameLength(
          index: deviceIndex,
          length: nameLength
        )
      }
      // A zero-length name is how an empty pairing slot can appear. The entry's
      // size is still known, so it is skipped rather than refused: one empty slot
      // on a future model must not blank the whole device list. The address bytes
      // of such a slot are padding and are deliberately not validated.
      guard nameLength > 0 else {
        offset += fixedLength
        continue
      }
      let addressBytes = bytes[offset..<(offset + 17)]
      guard
        let address = String(bytes: addressBytes, encoding: .ascii),
        isBluetoothAddress(address)
      else {
        throw TandemMultipointError.invalidAddress(index: deviceIndex)
      }
      let connectionIndex = Int(bytes[offset + 17])
      let bluetoothClassOfDevice: Int?
      if inquiry == .withBluetoothClassOfDevice {
        bluetoothClassOfDevice =
          (Int(bytes[offset + 18]) << 16)
          | (Int(bytes[offset + 19]) << 8)
          | Int(bytes[offset + 20])
      } else {
        bluetoothClassOfDevice = nil
      }
      let nameStart = offset + fixedLength
      let nameEnd = nameStart + nameLength
      guard bytes.count >= nameEnd else {
        throw TandemMultipointError.truncatedDevice(index: deviceIndex)
      }
      guard let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) else {
        throw TandemMultipointError.invalidName(index: deviceIndex)
      }
      devices.append(
        TandemMultipointDevice(
          address: address,
          connectionIndex: connectionIndex,
          name: name,
          bluetoothClassOfDevice: bluetoothClassOfDevice
        )
      )
      offset = nameEnd
    }

    let expectedLength = offset + 1
    guard bytes.count == expectedLength else {
      throw TandemMultipointError.trailingLength(
        expected: expectedLength,
        actual: bytes.count
      )
    }

    return TandemMultipointSnapshot(
      bluetoothMode: bluetoothMode,
      isControlEnabled: isControlEnabled,
      devices: devices,
      activeConnectionIndex: Int(bytes[offset])
    )
  }

  private static func request(
    sequence: UInt8,
    command: UInt8,
    inquiry: TandemMultipointInquiry
  ) throws -> TandemFrame {
    try TandemFrame(
      dataType: TandemFrame.table2DataType,
      sequence: sequence,
      payload: Data([command, inquiry.rawValue])
    )
  }

  private static func requireTable2(_ frame: TandemFrame) throws {
    guard frame.dataType == TandemFrame.table2DataType else {
      throw TandemMultipointError.unexpectedDataType(frame.dataType)
    }
  }

  private static func requirePrefix(
    _ bytes: [UInt8],
    command: UInt8,
    inquiry: TandemMultipointInquiry
  ) throws {
    let expected = [command, inquiry.rawValue]
    guard bytes.count >= 2, Array(bytes.prefix(2)) == expected else {
      throw TandemMultipointError.unexpectedPayload(
        expected: expected,
        actual: Array(bytes.prefix(2))
      )
    }
  }

  private static func isBluetoothAddress(_ value: String) -> Bool {
    let components = value.split(separator: ":", omittingEmptySubsequences: false)
    return components.count == 6
      && components.allSatisfy {
        $0.count == 2 && $0.allSatisfy(\.isHexDigit)
      }
  }
}
