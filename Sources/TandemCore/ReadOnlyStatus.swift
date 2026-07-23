import Foundation

/// The negotiated Bluetooth audio codec, as the device declares it.
///
/// Deliberately open rather than a closed enum: a future model's new codec code
/// must not fail the whole status parse — the codec is one display detail, and
/// refusing it would blank battery and everything else read in the same pass. An
/// unrecognised code is carried as-is and shown by its raw value; the named codes
/// keep their usual labels.
public struct TandemAudioCodec: RawRepresentable, Hashable, CustomStringConvertible, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let unsettled = TandemAudioCodec(rawValue: 0x00)
    public static let sbc = TandemAudioCodec(rawValue: 0x01)
    public static let aac = TandemAudioCodec(rawValue: 0x02)
    public static let ldac = TandemAudioCodec(rawValue: 0x10)
    public static let aptX = TandemAudioCodec(rawValue: 0x20)
    public static let aptXHD = TandemAudioCodec(rawValue: 0x21)
    public static let lc3 = TandemAudioCodec(rawValue: 0x30)
    public static let other = TandemAudioCodec(rawValue: 0xFF)

    /// True when this app has a name for the code; false for a code some future
    /// device declared that this app has never seen.
    public var isKnown: Bool {
        Self.namesByCode[rawValue] != nil
    }

    public var description: String {
        Self.namesByCode[rawValue] ?? String(format: "CODEC 0x%02X", rawValue)
    }

    private static let namesByCode: [UInt8: String] = [
        unsettled.rawValue: "UNSETTLED",
        sbc.rawValue: "SBC",
        aac.rawValue: "AAC",
        ldac.rawValue: "LDAC",
        aptX.rawValue: "aptX",
        aptXHD.rawValue: "aptX HD",
        lc3.rawValue: "LC3",
        other.rawValue: "OTHER",
    ]
}

public enum TandemBatteryChargingStatus: UInt8, CustomStringConvertible, Sendable {
    case notCharging = 0
    case charging = 1
    case unknown = 2
    case charged = 3

    public var description: String {
        switch self {
        case .notCharging: "not charging"
        case .charging: "charging"
        case .unknown: "unknown"
        case .charged: "charged"
        }
    }
}

public struct TandemEarbudBattery: Equatable, Sendable {
    public let leftPercent: UInt8
    public let leftChargingStatus: TandemBatteryChargingStatus
    public let rightPercent: UInt8
    public let rightChargingStatus: TandemBatteryChargingStatus
    public let leftThreshold: UInt8
    public let rightThreshold: UInt8
}

public struct TandemCaseBattery: Equatable, Sendable {
    public let percent: UInt8
    public let chargingStatus: TandemBatteryChargingStatus
    public let threshold: UInt8
}

public enum TandemBatteryQuery: UInt8, Sendable {
    case single = 0x00
    case leftRight = 0x01
    case chargingCase = 0x02
    case singleWithThreshold = 0x08
    case leftRightWithThreshold = 0x09
    case chargingCaseWithThreshold = 0x0A
}

public struct TandemBatteryUnit: Equatable, Sendable {
    public let percent: UInt8
    public let chargingStatus: TandemBatteryChargingStatus
    public let threshold: UInt8?
}

public struct TandemBatteryStatus: Equatable, Sendable {
    public let query: TandemBatteryQuery
    public let units: [TandemBatteryUnit]
}

public enum TandemStatusError: Error, Equatable, CustomStringConvertible, Sendable {
    case unexpectedDataType(UInt8)
    case unexpectedPayload(expected: [UInt8], actual: [UInt8])
    /// No longer thrown — an unknown codec now parses as itself — but kept so
    /// existing exhaustive handling of this error keeps compiling.
    case invalidCodec(UInt8)
    case invalidBatteryLength(expected: Int, actual: Int)
    case invalidBatteryPercent(UInt8)
    case invalidChargingStatus(UInt8)

    public var description: String {
        switch self {
        case .unexpectedDataType(let type):
            return String(format: "unexpected Tandem data type 0x%02X", type)
        case .unexpectedPayload(let expected, let actual):
            return "unexpected payload prefix \(actual); expected \(expected)"
        case .invalidCodec(let value):
            return String(format: "unknown audio codec 0x%02X", value)
        case .invalidBatteryLength(let expected, let actual):
            return "battery response length mismatch: expected \(expected), actual \(actual)"
        case .invalidBatteryPercent(let value):
            return "invalid battery percentage \(value)"
        case .invalidChargingStatus(let value):
            return "invalid battery charging status \(value)"
        }
    }
}

public enum TandemReadOnlyStatus {
    private static let commonGetStatus: UInt8 = 0x12
    private static let commonReturnStatus: UInt8 = 0x13
    private static let audioCodecInquiry: UInt8 = 0x02
    private static let powerGetStatus: UInt8 = 0x22
    private static let powerReturnStatus: UInt8 = 0x23
    private static let leftRightBatteryWithThresholdInquiry: UInt8 = 0x09
    private static let caseBatteryWithThresholdInquiry: UInt8 = 0x0A

    // The older generation's commands for the same values. Its battery types and the
    // codec codes are the ones still in use; only the command bytes moved.
    private static let legacyBatteryGet: UInt8 = 0x10
    /// The reply command the caller matches answers by.
    public static let legacyBatteryReturn: UInt8 = 0x11
    private static let legacyCodecGet: UInt8 = 0x18
    public static let legacyCodecReturn: UInt8 = 0x19
    private static let legacyCodecInquiry: UInt8 = 0x00

    public static func audioCodecRequest(
        sequence: UInt8,
        dialect: TandemDialect = .current
    ) throws -> TandemFrame {
        try request(
            sequence: sequence,
            command: dialect == .legacy ? legacyCodecGet : commonGetStatus,
            inquiry: dialect == .legacy ? legacyCodecInquiry : audioCodecInquiry
        )
    }

    public static func earbudBatteryRequest(sequence: UInt8) throws -> TandemFrame {
        try request(
            sequence: sequence,
            command: powerGetStatus,
            inquiry: leftRightBatteryWithThresholdInquiry
        )
    }

    public static func caseBatteryRequest(sequence: UInt8) throws -> TandemFrame {
        try request(
            sequence: sequence,
            command: powerGetStatus,
            inquiry: caseBatteryWithThresholdInquiry
        )
    }

    public static func batteryRequest(
        query: TandemBatteryQuery,
        sequence: UInt8,
        dialect: TandemDialect = .current
    ) throws -> TandemFrame {
        try request(
            sequence: sequence,
            command: dialect == .legacy ? legacyBatteryGet : powerGetStatus,
            inquiry: query.rawValue
        )
    }

    public static func parseAudioCodecResponse(
        _ frame: TandemFrame,
        dialect: TandemDialect = .current
    ) throws -> TandemAudioCodec {
        try requireTable1(frame)
        let command = dialect == .legacy ? legacyCodecReturn : commonReturnStatus
        let inquiry = dialect == .legacy ? legacyCodecInquiry : audioCodecInquiry
        let bytes = [UInt8](frame.payload)
        guard bytes.count == 3,
              bytes[0] == command,
              bytes[1] == inquiry
        else {
            throw TandemStatusError.unexpectedPayload(
                expected: [command, inquiry],
                actual: Array(bytes.prefix(2))
            )
        }
        // Any code parses: an unknown one is a new codec on a future device, not a
        // malformed answer, and must not fail the read (see `TandemAudioCodec`).
        return TandemAudioCodec(rawValue: bytes[2])
    }

    public static func parseEarbudBatteryResponse(
        _ frame: TandemFrame
    ) throws -> TandemEarbudBattery {
        try requireBatteryPrefix(
            frame,
            inquiry: leftRightBatteryWithThresholdInquiry,
            expectedLength: 8
        )
        let bytes = [UInt8](frame.payload)
        return TandemEarbudBattery(
            leftPercent: try percent(bytes[2]),
            leftChargingStatus: try chargingStatus(bytes[3]),
            rightPercent: try percent(bytes[4]),
            rightChargingStatus: try chargingStatus(bytes[5]),
            leftThreshold: try percent(bytes[6]),
            rightThreshold: try percent(bytes[7])
        )
    }

    public static func parseCaseBatteryResponse(
        _ frame: TandemFrame
    ) throws -> TandemCaseBattery {
        try requireBatteryPrefix(
            frame,
            inquiry: caseBatteryWithThresholdInquiry,
            expectedLength: 5
        )
        let bytes = [UInt8](frame.payload)
        return TandemCaseBattery(
            percent: try percent(bytes[2]),
            chargingStatus: try chargingStatus(bytes[3]),
            threshold: try percent(bytes[4])
        )
    }

    public static func parseBatteryResponse(
        _ frame: TandemFrame,
        query: TandemBatteryQuery,
        dialect: TandemDialect = .current
    ) throws -> TandemBatteryStatus {
        let unitCount: Int
        let hasThreshold: Bool
        switch query {
        case .single, .chargingCase:
            unitCount = 1
            hasThreshold = false
        case .singleWithThreshold, .chargingCaseWithThreshold:
            unitCount = 1
            hasThreshold = true
        case .leftRight:
            unitCount = 2
            hasThreshold = false
        case .leftRightWithThreshold:
            unitCount = 2
            hasThreshold = true
        }

        let expectedLength = 2 + (unitCount * 2) + (hasThreshold ? unitCount : 0)
        try requireBatteryPrefix(
            frame,
            inquiry: query.rawValue,
            expectedLength: expectedLength,
            command: dialect == .legacy ? legacyBatteryReturn : powerReturnStatus
        )
        let bytes = [UInt8](frame.payload)
        var units: [TandemBatteryUnit] = []
        for index in 0..<unitCount {
            let valueOffset = 2 + (index * 2)
            let thresholdOffset = 2 + (unitCount * 2) + index
            units.append(
                TandemBatteryUnit(
                    percent: try percent(bytes[valueOffset]),
                    chargingStatus: try chargingStatus(bytes[valueOffset + 1]),
                    threshold: hasThreshold ? try percent(bytes[thresholdOffset]) : nil
                )
            )
        }
        return TandemBatteryStatus(query: query, units: units)
    }

    private static func request(
        sequence: UInt8,
        command: UInt8,
        inquiry: UInt8
    ) throws -> TandemFrame {
        try TandemFrame(
            dataType: TandemFrame.table1DataType,
            sequence: sequence,
            payload: Data([command, inquiry])
        )
    }

    private static func requireTable1(_ frame: TandemFrame) throws {
        guard frame.dataType == TandemFrame.table1DataType else {
            throw TandemStatusError.unexpectedDataType(frame.dataType)
        }
    }

    private static func requireBatteryPrefix(
        _ frame: TandemFrame,
        inquiry: UInt8,
        expectedLength: Int,
        command: UInt8 = powerReturnStatus
    ) throws {
        try requireTable1(frame)
        let bytes = [UInt8](frame.payload)
        guard bytes.count == expectedLength else {
            throw TandemStatusError.invalidBatteryLength(
                expected: expectedLength,
                actual: bytes.count
            )
        }
        guard bytes[0] == command, bytes[1] == inquiry else {
            throw TandemStatusError.unexpectedPayload(
                expected: [command, inquiry],
                actual: Array(bytes.prefix(2))
            )
        }
    }

    private static func percent(_ value: UInt8) throws -> UInt8 {
        guard value <= 100 else { throw TandemStatusError.invalidBatteryPercent(value) }
        return value
    }

    private static func chargingStatus(
        _ value: UInt8
    ) throws -> TandemBatteryChargingStatus {
        guard let status = TandemBatteryChargingStatus(rawValue: value) else {
            throw TandemStatusError.invalidChargingStatus(value)
        }
        return status
    }
}
