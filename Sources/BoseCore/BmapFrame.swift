import Foundation

/// One BMAP packet: `[fblock, function, flags, payload_len, ...payload]`.
///
/// Far simpler than Tandem's framing — no start/end sentinels, no escaping, no
/// checksum, no acknowledgement. The single length byte delimits the payload,
/// which is why `BmapStreamParser` can split a run of concatenated packets just by
/// counting `4 + payload_len` bytes at a time.
///
/// `flags = (deviceId << 6) | (port << 4) | (op & 0x0F)`. On every packet this app
/// exchanges with the single-endpoint headsets in scope `deviceId` and `port` are
/// 0, so `flags` equals the operator. They are still decoded and preserved so a
/// frame round-trips to the exact bytes it came from.
public struct BmapFrame: Equatable, Sendable {
  public let fblock: UInt8
  public let function: UInt8
  /// Which logical device on a composite product the frame addresses (2 bits).
  public let deviceId: UInt8
  /// Which port on that device the frame addresses (2 bits).
  public let port: UInt8
  public let op: BmapOperator
  public let payload: Data

  public init(
    fblock: UInt8,
    function: UInt8,
    op: BmapOperator,
    payload: Data = Data(),
    deviceId: UInt8 = 0,
    port: UInt8 = 0
  ) throws {
    guard deviceId <= 0x03 else {
      throw BmapFrameError.deviceIdOutOfRange(deviceId)
    }
    guard port <= 0x03 else {
      throw BmapFrameError.portOutOfRange(port)
    }
    // The length is a single byte, so a payload beyond 255 cannot be framed.
    guard payload.count <= Int(UInt8.max) else {
      throw BmapFrameError.payloadTooLarge(payload.count)
    }
    self.fblock = fblock
    self.function = function
    self.op = op
    self.payload = payload
    self.deviceId = deviceId
    self.port = port
  }

  /// The composed flags byte, exactly as it sits on the wire.
  public var flags: UInt8 {
    (deviceId << 6) | (port << 4) | op.rawValue
  }

  /// The `(fblock, function)` pair this frame addresses.
  public var address: BmapFunctionAddress {
    BmapFunctionAddress(fblock: fblock, function: function)
  }

  public func encoded() -> Data {
    var bytes: [UInt8] = [fblock, function, flags, UInt8(payload.count)]
    bytes.append(contentsOf: payload)
    return Data(bytes)
  }

  /// Decodes exactly one frame from its complete wire bytes. The declared length
  /// must match what is present: a short or long buffer is a caller error here, in
  /// contrast to the stream parser which waits for more or resynchronises.
  public static func decode(_ bytes: [UInt8]) throws -> BmapFrame {
    guard bytes.count >= 4 else {
      throw BmapFrameError.tooShort(bytes.count)
    }
    let flags = bytes[2]
    guard let op = BmapOperator(rawValue: flags & 0x0F) else {
      throw BmapFrameError.invalidOperator(flags & 0x0F)
    }
    let declaredLength = Int(bytes[3])
    let expectedTotal = 4 + declaredLength
    guard bytes.count == expectedTotal else {
      throw BmapFrameError.lengthMismatch(
        declared: declaredLength,
        actual: bytes.count - 4
      )
    }
    return try BmapFrame(
      fblock: bytes[0],
      function: bytes[1],
      op: op,
      payload: Data(bytes[4..<expectedTotal]),
      deviceId: (flags >> 6) & 0x03,
      port: (flags >> 4) & 0x03
    )
  }

  public static func decode(_ data: Data) throws -> BmapFrame {
    try decode([UInt8](data))
  }
}

public enum BmapFrameError: Error, Equatable, CustomStringConvertible, Sendable {
  case deviceIdOutOfRange(UInt8)
  case portOutOfRange(UInt8)
  case payloadTooLarge(Int)
  case tooShort(Int)
  case invalidOperator(UInt8)
  case lengthMismatch(declared: Int, actual: Int)

  public var description: String {
    switch self {
    case .deviceIdOutOfRange(let value):
      "device id \(value) is outside 0...3"
    case .portOutOfRange(let value):
      "port \(value) is outside 0...3"
    case .payloadTooLarge(let count):
      "payload is too large to frame: \(count) bytes (max 255)"
    case .tooShort(let count):
      "frame is too short: \(count) bytes (need at least 4)"
    case .invalidOperator(let value):
      "invalid operator nibble \(value) (defined 0...7)"
    case .lengthMismatch(let declared, let actual):
      "payload length mismatch: declared \(declared), actual \(actual)"
    }
  }
}
