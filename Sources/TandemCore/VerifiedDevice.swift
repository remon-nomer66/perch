import Foundation

public struct TandemFirmwareVersion: Comparable, Equatable, Sendable {
    public let components: [Int]

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else {
                return nil
            }
            parsed.append(number)
        }
        components = parsed
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        compare(lhs.components, rhs.components) == 0
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        compare(lhs.components, rhs.components) < 0
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

public struct TandemDeviceFingerprint: Equatable, Sendable {
    public let protocolIdentifier: UInt32
    public let protocolFirstFlag: UInt8
    public let protocolSecondFlag: UInt8
    public let capabilityCode: UInt8
    public let capabilityIdentifierLength: Int
    public let modelName: String
    public let firmwareVersion: String
    public let table1Functions: [TandemSupportFunction]
    public let table2Functions: [TandemSupportFunction]
    /// Which generation of the conversation the device spoke during the handshake.
    public let dialect: TandemDialect

    public init(
        protocolIdentifier: UInt32,
        protocolFirstFlag: UInt8,
        protocolSecondFlag: UInt8,
        capabilityCode: UInt8,
        capabilityIdentifierLength: Int,
        modelName: String,
        firmwareVersion: String,
        table1Functions: [TandemSupportFunction],
        table2Functions: [TandemSupportFunction],
        dialect: TandemDialect = .current
    ) {
        self.protocolIdentifier = protocolIdentifier
        self.protocolFirstFlag = protocolFirstFlag
        self.protocolSecondFlag = protocolSecondFlag
        self.capabilityCode = capabilityCode
        self.capabilityIdentifierLength = capabilityIdentifierLength
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.table1Functions = table1Functions
        self.table2Functions = table2Functions
        self.dialect = dialect
    }
}

public enum TandemDeviceVerificationFailure: Error, Equatable, CustomStringConvertible, Sendable {
    case unverifiedModel(String)
    case unverifiedFirmware(model: String, firmware: String)
    case protocolMismatch(actual: UInt32)
    case protocolFlagsMismatch(first: UInt8, second: UInt8)
    case capabilityMismatch(code: UInt8, identifierLength: Int)
    case functionCountMismatch(table: Int, expected: Int, actual: Int)
    case missingRequiredFunction(table: Int, alternatives: [UInt8])
    case duplicateSupportFunction(table: Int, code: UInt8)
    case unverifiedFunctionVersion(code: UInt8, expected: UInt8, actual: UInt8)
    case noRecognizedControllableFunction

    public var description: String {
        switch self {
        case .unverifiedModel(let model):
            return "型名「\(model)」は実証済み機器の許可リストにありません"
        case .unverifiedFirmware(let model, let firmware):
            return "\(model) firmware \(firmware) は対応バージョン範囲外です"
        case .protocolMismatch(let actual):
            return String(format: "未検証のprotocol identifier 0x%08Xです", actual)
        case .protocolFlagsMismatch(let first, let second):
            return String(format: "未検証のprotocol flagsです（0x%02X, 0x%02X）", first, second)
        case .capabilityMismatch(let code, let identifierLength):
            return "未検証のcapabilityです（code \(code), identifier length \(identifierLength)）"
        case .functionCountMismatch(let table, let expected, let actual):
            return "Table \(table)の機能数が互換条件を満たしません（最低 \(expected)、応答 \(actual)）"
        case .missingRequiredFunction(let table, let alternatives):
            let values = alternatives.map { String(format: "0x%02X", $0) }.joined(separator: " / ")
            return "Table \(table)に実証済みの必須機能（\(values)）がありません"
        case .duplicateSupportFunction(let table, let code):
            return String(format: "Table %dのfunction code 0x%02Xが重複しています", table, code)
        case .unverifiedFunctionVersion(let code, let expected, let actual):
            return String(
                format: "function code 0x%02Xのversionが未検証です（検証済み %d、機器 %d）",
                code,
                expected,
                actual
            )
        case .noRecognizedControllableFunction:
            return "このアプリが型付きで制御できるfunction codeがありません"
        }
    }
}

public struct TandemExperimentalControlAssessment: Equatable, Sendable {
    public let isEligible: Bool
    public let reason: String
    public let referenceProfileID: String?
    public let recognizedTable1FunctionCodes: [UInt8]
}

public struct TandemVerifiedDeviceProfile: Equatable, Sendable {
    public let id: String
    public let modelName: String
    public let firmwareVersion: String
    public let protocolIdentifier: UInt32
    public let protocolFirstFlag: UInt8
    public let protocolSecondFlag: UInt8
    public let capabilityCode: UInt8
    public let capabilityIdentifierLength: Int
    public let table1FunctionCount: Int
    public let table2FunctionCount: Int
    public let requiredTable1FunctionGroups: [[UInt8]]
    public let requiredTable2FunctionGroups: [[UInt8]]
    /// Function versions observed on the verified firmware, for table 1 functions this
    /// application writes to.
    ///
    /// Newer firmware may keep a function code while changing the wire format of that
    /// function and advertising a new version. Matching on the code alone would let
    /// the existing encoders write an untested revision, so any pinned function must
    /// still report the version it was verified against.
    ///
    /// Codes absent from this table are unconstrained: they are either read-only or
    /// not used here.
    public let controlledTable1FunctionVersions: [UInt8: UInt8]

    public func validate(_ fingerprint: TandemDeviceFingerprint) throws {
        guard fingerprint.modelName == modelName else {
            throw TandemDeviceVerificationFailure.unverifiedModel(fingerprint.modelName)
        }
        guard supportsFirmware(fingerprint.firmwareVersion) else {
            throw TandemDeviceVerificationFailure.unverifiedFirmware(
                model: fingerprint.modelName,
                firmware: fingerprint.firmwareVersion
            )
        }
        try validateTransportCompatibility(fingerprint)
        try validateFunctions(
            fingerprint.table1Functions,
            table: 1,
            expectedCount: table1FunctionCount,
            requiredGroups: requiredTable1FunctionGroups
        )
        try validateControlledVersions(fingerprint.table1Functions)
        try validateFunctions(
            fingerprint.table2Functions,
            table: 2,
            expectedCount: table2FunctionCount,
            requiredGroups: requiredTable2FunctionGroups
        )
    }

    /// Minimum gate for an explicitly user-authorized experimental connection.
    /// Model, firmware, and feature inventory are intentionally not trusted here.
    public func validateTransportCompatibility(_ fingerprint: TandemDeviceFingerprint) throws {
        guard fingerprint.protocolIdentifier == protocolIdentifier else {
            throw TandemDeviceVerificationFailure.protocolMismatch(
                actual: fingerprint.protocolIdentifier
            )
        }
        guard fingerprint.protocolFirstFlag == protocolFirstFlag,
              fingerprint.protocolSecondFlag == protocolSecondFlag
        else {
            throw TandemDeviceVerificationFailure.protocolFlagsMismatch(
                first: fingerprint.protocolFirstFlag,
                second: fingerprint.protocolSecondFlag
            )
        }
        guard fingerprint.capabilityCode == capabilityCode,
              fingerprint.capabilityIdentifierLength == capabilityIdentifierLength
        else {
            throw TandemDeviceVerificationFailure.capabilityMismatch(
                code: fingerprint.capabilityCode,
                identifierLength: fingerprint.capabilityIdentifierLength
            )
        }
    }

    /// True for firmware this profile can vouch for. The verified revision itself
    /// always passes. A newer revision passes only when the profile pins the versions
    /// of the functions this application writes to: those pins are what detect a wire
    /// format change (`validateControlledVersions`), and without them a newer firmware
    /// could change any format while keeping every function code. An unpinned newer
    /// firmware instead goes down the unverified caveat path, where the read-back
    /// check is the protection.
    public func supportsFirmware(_ candidate: String) -> Bool {
        guard let verified = TandemFirmwareVersion(firmwareVersion),
              let actual = TandemFirmwareVersion(candidate)
        else {
            return false
        }
        if actual == verified { return true }
        return actual > verified && !controlledTable1FunctionVersions.isEmpty
    }

    private func validateControlledVersions(_ functions: [TandemSupportFunction]) throws {
        for function in functions {
            guard let expected = controlledTable1FunctionVersions[function.code] else { continue }
            guard function.version == expected else {
                throw TandemDeviceVerificationFailure.unverifiedFunctionVersion(
                    code: function.code,
                    expected: expected,
                    actual: function.version
                )
            }
        }
    }

    private func validateFunctions(
        _ functions: [TandemSupportFunction],
        table: Int,
        expectedCount: Int,
        requiredGroups: [[UInt8]]
    ) throws {
        guard functions.count >= expectedCount else {
            throw TandemDeviceVerificationFailure.functionCountMismatch(
                table: table,
                expected: expectedCount,
                actual: functions.count
            )
        }
        var codes: Set<UInt8> = []
        for function in functions where !codes.insert(function.code).inserted {
            throw TandemDeviceVerificationFailure.duplicateSupportFunction(
                table: table,
                code: function.code
            )
        }
        for alternatives in requiredGroups where alternatives.allSatisfy({ !codes.contains($0) }) {
            throw TandemDeviceVerificationFailure.missingRequiredFunction(
                table: table,
                alternatives: alternatives
            )
        }
    }
}

public enum TandemVerifiedDeviceRegistry {
    /// Functions for which the desktop implementation has a typed capability/current-value
    /// parser and a bounded SET encoder. General Setting D1...D4 is excluded here because its
    /// purpose cannot be known until a feature-specific capability query succeeds.
    public static let experimentallyControllableTable1Codes: Set<UInt8> = [
        0x57,       // equalizer
        0x6D,       // NC / ambient sound
        0xE4, 0xEB, // listening mode / BGM
        0xFC,       // Speak-to-Chat Type 2
    ]
    /// Verified on 2026-07-21 over RFCOMM channel 9 with a WF-1000XM6 running 1.5.0.
    ///
    /// The full support-function fingerprint is retained in each session. Until it can be
    /// re-read from the device, this profile requires the observed counts and every function
    /// family used by this application. With no pinned function versions, only this exact
    /// firmware is `verified`; a newer revision keeps the caveated unverified path instead.
    public static let wf1000xm6Firmware150 = TandemVerifiedDeviceProfile(
        id: "wf-1000xm6-fw-1.5.0-rfcomm-v2",
        modelName: "WF-1000XM6",
        firmwareVersion: "1.5.0",
        protocolIdentifier: 0x0300_3002,
        protocolFirstFlag: 0,
        protocolSecondFlag: 0,
        capabilityCode: 6,
        capabilityIdentifierLength: 17,
        table1FunctionCount: 49,
        table2FunctionCount: 16,
        requiredTable1FunctionGroups: [
            [0x12],       // codec indicator
            [0x29, 0x21], // left/right battery
            [0x2A, 0x22], // charging-case battery
            [0x57],       // equalizer
            [0x6D],       // NC / ambient sound
            [0xE4, 0xEB], // listening mode / BGM
            [0xFC],       // Speak-to-Chat Type 2
            [0xD1, 0xD2, 0xD3, 0xD4], // General Setting / sidetone
        ],
        requiredTable2FunctionGroups: [
            [0x30, 0x32, 0x33], // multipoint device management
        ],
        // Not yet populated: the versions the device advertises for these functions
        // have not been captured from hardware. Until they are, a firmware that
        // changes the wire format of a controlled function while keeping its code
        // will still pass. Capturing them is a Phase 1 deliverable.
        controlledTable1FunctionVersions: [:]
    )

    /// Verified on 2026-07-22 over RFCOMM channel 9 with a WH-1000XM6 running 3.1.5.
    ///
    /// The implementation stayed capability-driven throughout — every control reads the
    /// device's own declared parameters rather than any value pinned to this model. This
    /// profile only records that the headphone was confirmed to work, so it stops
    /// carrying the unverified caveat. A headphone reports one battery, not left/right,
    /// which is the only shape difference from the earbuds' profile.
    public static let wh1000xm6Firmware315 = TandemVerifiedDeviceProfile(
        id: "wh-1000xm6-fw-3.1.5-rfcomm-v2",
        modelName: "WH-1000XM6",
        firmwareVersion: "3.1.5",
        protocolIdentifier: 0x0300_3032,
        protocolFirstFlag: 0,
        protocolSecondFlag: 0,
        capabilityCode: 5,
        capabilityIdentifierLength: 17,
        table1FunctionCount: 45,
        table2FunctionCount: 16,
        requiredTable1FunctionGroups: [
            [0x12],                    // codec indicator
            // Single (headband) battery. Deliberately without an 0x28
            // (with-threshold) alternative: this exact firmware was observed to
            // declare 0x20, and these groups only ever gate that firmware — any
            // other revision is rejected as unverified before function groups are
            // checked and takes the caveated path, where battery is read
            // capability-driven. An unobserved alternative would loosen the gate
            // to a shape nobody has seen.
            [0x20],
            [0x57],                    // equalizer
            [0x6D],                    // NC / ambient sound
            [0xE4, 0xEB],              // listening mode / BGM
            [0xFC],                    // Speak-to-Chat Type 2
            [0xD1, 0xD2, 0xD3, 0xD4],  // General Setting / sidetone
        ],
        requiredTable2FunctionGroups: [
            [0x30, 0x32, 0x33], // multipoint / pairing device management
        ],
        // Left empty like the earbuds' profile: the versions this firmware advertises
        // for the controlled functions are known (EQ 19, NC 11, BGM 16, cinema 17,
        // S2C 13), but pinning them is deferred so both profiles stay consistent.
        controlledTable1FunctionVersions: [:]
    )

    public static let profiles: [TandemVerifiedDeviceProfile] = [
        wf1000xm6Firmware150,
        wh1000xm6Firmware315,
    ]

    public static func containsModel(_ modelName: String) -> Bool {
        profiles.contains { $0.modelName == modelName }
    }

    public static func containsFirmware(modelName: String, firmwareVersion: String) -> Bool {
        profiles.contains {
            $0.modelName == modelName && $0.supportsFirmware(firmwareVersion)
        }
    }

    public static func verifiedProfile(
        for fingerprint: TandemDeviceFingerprint
    ) throws -> TandemVerifiedDeviceProfile {
        guard profiles.contains(where: { $0.modelName == fingerprint.modelName }) else {
            throw TandemDeviceVerificationFailure.unverifiedModel(fingerprint.modelName)
        }
        guard let firmwareProfile = profiles.first(where: {
            $0.modelName == fingerprint.modelName
                && $0.supportsFirmware(fingerprint.firmwareVersion)
        }) else {
            throw TandemDeviceVerificationFailure.unverifiedFirmware(
                model: fingerprint.modelName,
                firmware: fingerprint.firmwareVersion
            )
        }
        try firmwareProfile.validate(fingerprint)
        return firmwareProfile
    }

    /// Whether a device that failed verification may still be offered the caveated
    /// write path, or must stay read-only.
    ///
    /// Verification ends in one of three ways, deliberately distinct:
    /// - A verified device never comes through here.
    /// - A model or firmware the registry has simply not verified is the experimental
    ///   case: writing is permitted, behind the on-screen caveat, when the
    ///   experimental gate recognises the device's conversation and at least one
    ///   controllable function.
    /// - Every other failure is a structural refusal — the device is not shaped like
    ///   anything that was verified — and a refusal must never reach a writable
    ///   state.
    public static func permitsUnverifiedWrites(
        for fingerprint: TandemDeviceFingerprint,
        rejectedWith reason: TandemDeviceVerificationFailure
    ) -> Bool {
        switch reason {
        case .unverifiedModel, .unverifiedFirmware:
            return experimentalControlAssessment(for: fingerprint).isEligible
        default:
            return false
        }
    }

    public static func experimentalReferenceProfile(
        for fingerprint: TandemDeviceFingerprint
    ) throws -> TandemVerifiedDeviceProfile {
        let profile = try experimentalTransportReferenceProfile(for: fingerprint)
        try validateExperimentalFunctionInventory(fingerprint)
        return profile
    }

    public static func experimentalControlAssessment(
        for fingerprint: TandemDeviceFingerprint
    ) -> TandemExperimentalControlAssessment {
        do {
            let profile = try experimentalReferenceProfile(for: fingerprint)
            let recognized = recognizedExperimentalFunctions(fingerprint)
            return TandemExperimentalControlAssessment(
                isEligible: true,
                reason: "Tandem通信形式と既知の制御機能を確認しました",
                referenceProfileID: profile.id,
                recognizedTable1FunctionCodes: recognized
            )
        } catch let failure as TandemDeviceVerificationFailure {
            return TandemExperimentalControlAssessment(
                isEligible: false,
                reason: failure.description,
                referenceProfileID: nil,
                recognizedTable1FunctionCodes: recognizedExperimentalFunctions(fingerprint)
            )
        } catch {
            return TandemExperimentalControlAssessment(
                isEligible: false,
                reason: String(describing: error),
                referenceProfileID: nil,
                recognizedTable1FunctionCodes: recognizedExperimentalFunctions(fingerprint)
            )
        }
    }

    private static func experimentalTransportReferenceProfile(
        for fingerprint: TandemDeviceFingerprint
    ) throws -> TandemVerifiedDeviceProfile {
        var lastFailure: TandemDeviceVerificationFailure?
        for profile in profiles {
            do {
                try profile.validateTransportCompatibility(fingerprint)
                return profile
            } catch let failure as TandemDeviceVerificationFailure {
                lastFailure = failure
            }
        }
        throw lastFailure ?? TandemDeviceVerificationFailure.protocolMismatch(
            actual: fingerprint.protocolIdentifier
        )
    }

    private static func validateExperimentalFunctionInventory(
        _ fingerprint: TandemDeviceFingerprint
    ) throws {
        try validateUniqueFunctions(fingerprint.table1Functions, table: 1)
        try validateUniqueFunctions(fingerprint.table2Functions, table: 2)
        guard !recognizedExperimentalFunctions(fingerprint).isEmpty else {
            throw TandemDeviceVerificationFailure.noRecognizedControllableFunction
        }
    }

    private static func validateUniqueFunctions(
        _ functions: [TandemSupportFunction],
        table: Int
    ) throws {
        var codes: Set<UInt8> = []
        for function in functions where !codes.insert(function.code).inserted {
            throw TandemDeviceVerificationFailure.duplicateSupportFunction(
                table: table,
                code: function.code
            )
        }
    }

    private static func recognizedExperimentalFunctions(
        _ fingerprint: TandemDeviceFingerprint
    ) -> [UInt8] {
        fingerprint.table1Functions
            .map(\.code)
            .filter { experimentallyControllableTable1Codes.contains($0) }
            .sorted()
    }
}
