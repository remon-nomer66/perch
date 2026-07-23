import Foundation

public struct TandemFrame: Equatable, Sendable {
    public static let startByte: UInt8 = 0x3E
    public static let endByte: UInt8 = 0x3C
    public static let escapeByte: UInt8 = 0x3D
    public static let ackDataType: UInt8 = 0x01
    public static let table1DataType: UInt8 = 0x0C
    public static let table2DataType: UInt8 = 0x0E
    /// One-way "shot" counterparts of the two-way data types, each the two-way value
    /// plus 0x10: 0x1C carries the same table-1 content as 0x0C, 0x1E the same
    /// table-2 content as 0x0E, but the sender does not wait for an ACK.
    public static let shotTable1DataType: UInt8 = 0x1C
    public static let shotTable2DataType: UInt8 = 0x1E
    /// Every shot data type the protocol defines, including the ones whose two-way
    /// counterparts this app never exchanges. Acknowledging a shot frame would
    /// answer a message whose sender is not listening for one and desynchronise the
    /// alternating sequence bit, so the router must skip all of these.
    public static let shotDataTypes: Set<UInt8> = [
        0x10, 0x12, 0x19, 0x1A, shotTable1DataType, 0x1D, shotTable2DataType,
    ]

    public let dataType: UInt8
    public let sequence: UInt8
    public let payload: Data

    public init(dataType: UInt8, sequence: UInt8, payload: Data) throws {
        guard sequence == 0 || sequence == 1 else {
            throw TandemFrameError.invalidSequence(sequence)
        }
        guard payload.count <= Int(UInt32.max) else {
            throw TandemFrameError.payloadTooLarge(payload.count)
        }
        self.dataType = dataType
        self.sequence = sequence
        self.payload = payload
    }

    public var requiresAcknowledgement: Bool {
        dataType != Self.ackDataType && !Self.shotDataTypes.contains(dataType)
    }

    public func encoded() -> Data {
        let payloadLength = UInt32(payload.count)
        var body: [UInt8] = [
            dataType,
            sequence,
            UInt8((payloadLength >> 24) & 0xFF),
            UInt8((payloadLength >> 16) & 0xFF),
            UInt8((payloadLength >> 8) & 0xFF),
            UInt8(payloadLength & 0xFF)
        ]
        body.append(contentsOf: payload)
        body.append(body.reduce(0) { $0 &+ $1 })

        var wire: [UInt8] = [Self.startByte]
        wire.reserveCapacity(body.count + 2)
        for byte in body {
            switch byte {
            case Self.endByte, Self.escapeByte, Self.startByte:
                wire.append(Self.escapeByte)
                wire.append(byte & 0xEF)
            default:
                wire.append(byte)
            }
        }
        wire.append(Self.endByte)
        return Data(wire)
    }

    public static func acknowledgement(for receivedSequence: UInt8) throws -> TandemFrame {
        guard receivedSequence == 0 || receivedSequence == 1 else {
            throw TandemFrameError.invalidSequence(receivedSequence)
        }
        return try TandemFrame(
            dataType: ackDataType,
            sequence: receivedSequence ^ 1,
            payload: Data()
        )
    }
}

public enum TandemFrameError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSequence(UInt8)
    case payloadTooLarge(Int)
    case invalidEscape(UInt8)
    case frameTooShort(Int)
    case frameTooLong(maximum: Int)
    case declaredLengthTooLarge(Int)
    case lengthMismatch(declared: Int, actual: Int)
    case checksumMismatch(expected: UInt8, actual: UInt8)

    public var description: String {
        switch self {
        case .invalidSequence(let sequence):
            return "invalid sequence number \(sequence)"
        case .payloadTooLarge(let count):
            return "payload is too large: \(count) bytes"
        case .invalidEscape(let byte):
            return String(format: "invalid escaped byte 0x%02X", byte)
        case .frameTooShort(let count):
            return "frame body is too short: \(count) bytes"
        case .frameTooLong(let maximum):
            return "frame body exceeded \(maximum) bytes without a terminator"
        case .declaredLengthTooLarge(let count):
            return "declared payload is too large: \(count) bytes"
        case .lengthMismatch(let declared, let actual):
            return "payload length mismatch: declared \(declared), actual \(actual)"
        case .checksumMismatch(let expected, let actual):
            return String(
                format: "checksum mismatch: expected 0x%02X, actual 0x%02X",
                expected,
                actual
            )
        }
    }
}

public struct TandemStreamDecoder: Sendable {
    public var maximumPayloadLength: Int

    private enum State: Sendable {
        case waitingForStart
        case body
        case escaped
    }

    private var state: State = .waitingForStart
    private var body: [UInt8] = []
    /// Frames decoded before an error stopped the previous `append`, handed back at
    /// the start of the next call: a bad frame must cost only itself, never its
    /// neighbours in the stream.
    private var pending: [TandemFrame] = []

    public init(maximumPayloadLength: Int = 65_536) {
        self.maximumPayloadLength = maximumPayloadLength
    }

    /// The largest unescaped body a legitimate frame can have: six header bytes,
    /// the payload cap, and the checksum. Accumulating beyond this means the
    /// terminator is not coming, so the decoder must stop buffering rather than
    /// grow without bound on a corrupted or hostile stream.
    private var maximumBodyLength: Int { maximumPayloadLength + 7 }

    public mutating func append(_ data: Data) throws -> [TandemFrame] {
        var frames = pending
        pending.removeAll()
        // The whole chunk is scanned before the first error is reported, so the
        // bytes after a bad frame are not lost with it: the decoder resynchronises
        // on the next start byte and keeps decoding. Frames decoded in a call that
        // throws are stashed and returned by the next call.
        var firstError: TandemFrameError?
        func record(_ error: TandemFrameError) {
            if firstError == nil { firstError = error }
            body.removeAll(keepingCapacity: true)
            state = .waitingForStart
        }

        for byte in data {
            switch state {
            case .waitingForStart:
                if byte == TandemFrame.startByte {
                    body.removeAll(keepingCapacity: true)
                    state = .body
                }

            case .body:
                switch byte {
                case TandemFrame.startByte:
                    body.removeAll(keepingCapacity: true)
                case TandemFrame.endByte:
                    do {
                        frames.append(try decodeBody())
                        body.removeAll(keepingCapacity: true)
                        state = .waitingForStart
                    } catch let error as TandemFrameError {
                        record(error)
                    }
                case TandemFrame.escapeByte:
                    state = .escaped
                default:
                    if body.count >= maximumBodyLength {
                        record(.frameTooLong(maximum: maximumBodyLength))
                    } else {
                        body.append(byte)
                    }
                }

            case .escaped:
                guard byte == 0x2C || byte == 0x2D || byte == 0x2E else {
                    record(.invalidEscape(byte))
                    continue
                }
                if body.count >= maximumBodyLength {
                    record(.frameTooLong(maximum: maximumBodyLength))
                } else {
                    body.append(byte | 0x10)
                    state = .body
                }
            }
        }

        if let error = firstError {
            pending = frames
            throw error
        }
        return frames
    }

    private func decodeBody() throws -> TandemFrame {
        try Self.decodeBody(body, maximumPayloadLength: maximumPayloadLength)
    }

    /// Decodes an unescaped frame body. Exposed so transports can reuse the same
    /// validation while applying their own buffering and recovery policy.
    public static func decodeBody(
        _ body: [UInt8],
        maximumPayloadLength: Int
    ) throws -> TandemFrame {
        guard body.count >= 7 else {
            throw TandemFrameError.frameTooShort(body.count)
        }

        let declaredLength =
            (Int(body[2]) << 24)
            | (Int(body[3]) << 16)
            | (Int(body[4]) << 8)
            | Int(body[5])
        guard declaredLength <= maximumPayloadLength else {
            throw TandemFrameError.declaredLengthTooLarge(declaredLength)
        }

        let actualLength = body.count - 7
        guard declaredLength == actualLength else {
            throw TandemFrameError.lengthMismatch(
                declared: declaredLength,
                actual: actualLength
            )
        }

        let actualChecksum = body[body.count - 1]
        let expectedChecksum = body.dropLast().reduce(0) { $0 &+ $1 }
        guard actualChecksum == expectedChecksum else {
            throw TandemFrameError.checksumMismatch(
                expected: expectedChecksum,
                actual: actualChecksum
            )
        }

        return try TandemFrame(
            dataType: body[0],
            sequence: body[1],
            payload: Data(body[6..<(6 + declaredLength)])
        )
    }
}
