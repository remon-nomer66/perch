import Foundation

/// Which generation of the conversation a device speaks.
///
/// The device itself says which, by the shape of its handshake answers: the current
/// generation replies to the protocol request with eight bytes, the older one — the
/// WF-1000XM3 era — with four. Everything downstream keys on this, never on a model
/// name.
public enum TandemDialect: String, Equatable, Sendable {
    case current
    case legacy
}

public enum TandemConnectCommand: UInt8, Sendable {
    case getProtocolInfo = 0x00
    case returnProtocolInfo = 0x01
    case getCapabilityInfo = 0x02
    case returnCapabilityInfo = 0x03
    case getDeviceInfo = 0x04
    case returnDeviceInfo = 0x05
    case getSupportFunction = 0x06
    case returnSupportFunction = 0x07
}

public enum TandemDeviceInfoType: UInt8, Sendable {
    case modelName = 0x01
    case firmwareVersion = 0x02
    case seriesAndColor = 0x03
    case instructionGuide = 0x04
}

public struct TandemProtocolInfo: Equatable, Sendable {
    public let identifier: UInt32
    public let firstFlag: UInt8
    public let secondFlag: UInt8
    /// Derived from the answer's shape; see `TandemDialect`.
    public let dialect: TandemDialect
}

public struct TandemCapabilityInfo: Equatable, Sendable {
    public let capabilityCode: UInt8
    public let identifierLength: Int
}

public struct TandemDeviceInfo: Equatable, Sendable {
    public let type: TandemDeviceInfoType
    public let value: String
}

public struct TandemSupportFunction: Equatable, Hashable, Sendable {
    public let code: UInt8
    public let version: UInt8

    public init(code: UInt8, version: UInt8) {
        self.code = code
        self.version = version
    }
}

public enum TandemHandshakeError: Error, Equatable, CustomStringConvertible, Sendable {
    case unexpectedDataType(UInt8)
    case unexpectedCommand(UInt8)
    case invalidProtocolPayloadLength(Int)
    case invalidCapabilityPayloadLength(Int)
    case invalidCapabilityIdentifierLength(declared: Int, actual: Int)
    case invalidInquiredType(expected: UInt8, actual: UInt8)
    case invalidDeviceInfoPayloadLength(Int)
    case invalidDeviceInfoType(UInt8)
    case invalidDeviceInfoStringLength(declared: Int, actual: Int)
    case invalidDeviceInfoString
    case invalidSupportPayloadLength(Int)
    case invalidSupportCount(declared: Int, actual: Int)

    public var description: String {
        switch self {
        case .unexpectedDataType(let type):
            return String(format: "unexpected Tandem data type 0x%02X", type)
        case .unexpectedCommand(let command):
            return String(format: "unexpected Tandem command 0x%02X", command)
        case .invalidProtocolPayloadLength(let count):
            return "protocol response must contain 8 bytes, got \(count)"
        case .invalidCapabilityPayloadLength(let count):
            return "capability response is too short: \(count) bytes"
        case .invalidCapabilityIdentifierLength(let declared, let actual):
            return "capability identifier length mismatch: declared \(declared), actual \(actual)"
        case .invalidInquiredType(let expected, let actual):
            return String(
                format: "unexpected inquired type 0x%02X; expected 0x%02X",
                actual,
                expected
            )
        case .invalidDeviceInfoPayloadLength(let count):
            return "device info response is too short: \(count) bytes"
        case .invalidDeviceInfoType(let type):
            return String(format: "unknown device info type 0x%02X", type)
        case .invalidDeviceInfoStringLength(let declared, let actual):
            return "device info string length mismatch: declared \(declared), actual \(actual)"
        case .invalidDeviceInfoString:
            return "device info response did not contain valid UTF-8"
        case .invalidSupportPayloadLength(let count):
            return "support function response is too short: \(count) bytes"
        case .invalidSupportCount(let declared, let actual):
            return "support function count mismatch: declared \(declared), actual \(actual)"
        }
    }
}

public enum TandemReadOnlyHandshake {
    public static let fixedInquiredType: UInt8 = 0x00

    public static func protocolRequest(sequence: UInt8) throws -> TandemFrame {
        try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: sequence,
            payload: Data([TandemConnectCommand.getProtocolInfo.rawValue, fixedInquiredType])
        )
    }

    public static func capabilityRequest(sequence: UInt8) throws -> TandemFrame {
        try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: sequence,
            payload: Data([TandemConnectCommand.getCapabilityInfo.rawValue, fixedInquiredType])
        )
    }

    public static func deviceInfoRequest(
        _ type: TandemDeviceInfoType,
        sequence: UInt8
    ) throws -> TandemFrame {
        try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: sequence,
            payload: Data([TandemConnectCommand.getDeviceInfo.rawValue, type.rawValue])
        )
    }

    public static func supportFunctionRequest(
        dataType: UInt8,
        sequence: UInt8
    ) throws -> TandemFrame {
        guard dataType == TandemFrame.table1DataType
            || dataType == TandemFrame.table2DataType
        else {
            throw TandemHandshakeError.unexpectedDataType(dataType)
        }
        return try TandemFrame(
            dataType: dataType,
            sequence: sequence,
            payload: Data([TandemConnectCommand.getSupportFunction.rawValue, fixedInquiredType])
        )
    }

    public static func parseProtocolResponse(_ frame: TandemFrame) throws -> TandemProtocolInfo {
        try requireTable1(frame)
        let bytes = [UInt8](frame.payload)
        // The current generation answers 8 bytes: a four-byte identifier and two
        // flags. The older one answers 4: a two-byte version and no flags. Both are
        // real devices, so both are read; anything else is still refused.
        guard bytes.count == 8 || bytes.count == 4 else {
            throw TandemHandshakeError.invalidProtocolPayloadLength(bytes.count)
        }
        guard bytes[0] == TandemConnectCommand.returnProtocolInfo.rawValue else {
            throw TandemHandshakeError.unexpectedCommand(bytes[0])
        }
        guard bytes[1] == fixedInquiredType else {
            throw TandemHandshakeError.invalidInquiredType(
                expected: fixedInquiredType,
                actual: bytes[1]
            )
        }
        guard bytes.count == 8 else {
            return TandemProtocolInfo(
                identifier: (UInt32(bytes[2]) << 8) | UInt32(bytes[3]),
                firstFlag: 0,
                secondFlag: 0,
                dialect: .legacy
            )
        }
        let identifier =
            (UInt32(bytes[2]) << 24)
            | (UInt32(bytes[3]) << 16)
            | (UInt32(bytes[4]) << 8)
            | UInt32(bytes[5])
        return TandemProtocolInfo(
            identifier: identifier,
            firstFlag: bytes[6],
            secondFlag: bytes[7],
            dialect: .current
        )
    }

    public static func parseCapabilityResponse(
        _ frame: TandemFrame
    ) throws -> TandemCapabilityInfo {
        try requireTable1(frame)
        let bytes = [UInt8](frame.payload)
        guard bytes.count >= 4 else {
            throw TandemHandshakeError.invalidCapabilityPayloadLength(bytes.count)
        }
        guard bytes[0] == TandemConnectCommand.returnCapabilityInfo.rawValue else {
            throw TandemHandshakeError.unexpectedCommand(bytes[0])
        }
        guard bytes[1] == fixedInquiredType else {
            throw TandemHandshakeError.invalidInquiredType(
                expected: fixedInquiredType,
                actual: bytes[1]
            )
        }
        let declaredLength = Int(bytes[3])
        let actualLength = bytes.count - 4
        guard declaredLength == actualLength else {
            throw TandemHandshakeError.invalidCapabilityIdentifierLength(
                declared: declaredLength,
                actual: actualLength
            )
        }
        return TandemCapabilityInfo(
            capabilityCode: bytes[2],
            identifierLength: declaredLength
        )
    }

    public static func parseDeviceInfoResponse(
        _ frame: TandemFrame,
        expectedType: TandemDeviceInfoType
    ) throws -> TandemDeviceInfo {
        try requireTable1(frame)
        let bytes = [UInt8](frame.payload)
        guard bytes.count >= 3 else {
            throw TandemHandshakeError.invalidDeviceInfoPayloadLength(bytes.count)
        }
        guard bytes[0] == TandemConnectCommand.returnDeviceInfo.rawValue else {
            throw TandemHandshakeError.unexpectedCommand(bytes[0])
        }
        guard let type = TandemDeviceInfoType(rawValue: bytes[1]) else {
            throw TandemHandshakeError.invalidDeviceInfoType(bytes[1])
        }
        guard type == expectedType else {
            throw TandemHandshakeError.invalidDeviceInfoType(bytes[1])
        }
        let declaredLength = Int(bytes[2])
        let actualLength = bytes.count - 3
        guard declaredLength == actualLength else {
            throw TandemHandshakeError.invalidDeviceInfoStringLength(
                declared: declaredLength,
                actual: actualLength
            )
        }
        guard let value = String(bytes: bytes.dropFirst(3), encoding: .utf8) else {
            throw TandemHandshakeError.invalidDeviceInfoString
        }
        return TandemDeviceInfo(type: type, value: value)
    }

    public static func parseSupportFunctionResponse(
        _ frame: TandemFrame,
        expectedDataType: UInt8
    ) throws -> [TandemSupportFunction] {
        guard frame.dataType == expectedDataType else {
            throw TandemHandshakeError.unexpectedDataType(frame.dataType)
        }
        let bytes = [UInt8](frame.payload)
        guard bytes.count >= 3 else {
            throw TandemHandshakeError.invalidSupportPayloadLength(bytes.count)
        }
        guard bytes[0] == TandemConnectCommand.returnSupportFunction.rawValue else {
            throw TandemHandshakeError.unexpectedCommand(bytes[0])
        }
        // A wrong inquired type is its own failure: reporting it as a count
        // mismatch used to send whoever read the diagnostic to the wrong field.
        guard bytes[1] == fixedInquiredType else {
            throw TandemHandshakeError.invalidInquiredType(
                expected: fixedInquiredType,
                actual: bytes[1]
            )
        }
        let declaredCount = Int(bytes[2])
        // The current generation lists code and version pairs; the older one lists
        // the codes alone. The two shapes cannot collide for a non-empty list, so
        // the byte count says which dialect answered.
        if bytes.count == 3 + (declaredCount * 2) {
            return stride(from: 3, to: bytes.count, by: 2).map {
                TandemSupportFunction(code: bytes[$0], version: bytes[$0 + 1])
            }
        }
        if declaredCount > 0, bytes.count == 3 + declaredCount {
            return bytes[3...].map { TandemSupportFunction(code: $0, version: 0) }
        }
        throw TandemHandshakeError.invalidSupportCount(
            declared: declaredCount,
            actual: (bytes.count - 3) / 2
        )
    }

    private static func requireTable1(_ frame: TandemFrame) throws {
        guard frame.dataType == TandemFrame.table1DataType else {
            throw TandemHandshakeError.unexpectedDataType(frame.dataType)
        }
    }
}
