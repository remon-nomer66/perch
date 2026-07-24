import Foundation

/// Splits a byte stream into `BmapFrame`s using only the length byte.
///
/// BMAP has no start/end sentinels, so — unlike `TandemStreamDecoder`, which can
/// hunt for the next start byte — resynchronisation here is length-driven. In the
/// normal case a run of concatenated packets is cut into frames by reading the
/// length byte and taking `4 + length` bytes at a time; a frame split across
/// several `append` calls is carried over until the rest arrives.
///
/// Corruption is detected as an invalid operator nibble (8...15) in a frame's flags
/// byte. Without a sentinel the safest recovery is to trust the length byte and skip
/// the whole damaged frame, which cleanly re-locks on the following packet boundary
/// when only the operator was mangled. A caller-set `maximumBufferedBytes` bounds
/// the buffer so a hostile or wedged stream cannot grow memory without limit.
public struct BmapStreamParser: Sendable {
  /// The most unprocessed bytes the parser will hold. Must be at least a full frame
  /// (259 bytes: 4 header + 255 payload) or a legitimate large frame could never be
  /// assembled. Exceeding it is reported as `.bufferOverflow`.
  public var maximumBufferedBytes: Int

  private var buffer: [UInt8] = []
  /// Frames decoded before an error stopped the previous `append`, handed back at the
  /// start of the next call so a fault costs only itself, never the frames already
  /// recovered alongside it.
  private var pending: [BmapFrame] = []

  public init(maximumBufferedBytes: Int = 65_536) {
    self.maximumBufferedBytes = maximumBufferedBytes
  }

  public mutating func append(_ data: Data) throws -> [BmapFrame] {
    var frames = pending
    pending.removeAll()
    buffer.append(contentsOf: data)

    // The first fault is remembered but does not stop the scan: draining continues so
    // frames after the damaged one are still recovered and returned.
    var firstError: BmapStreamError?
    func fail(_ error: BmapStreamError) {
      if firstError == nil { firstError = error }
    }

    var offset = 0
    while buffer.count - offset >= 4 {
      let flags = buffer[offset + 2]
      let declaredLength = Int(buffer[offset + 3])
      let total = 4 + declaredLength

      guard BmapOperator(rawValue: flags & 0x0F) != nil else {
        // Damaged header. Skip the frame its length byte describes once it has fully
        // arrived; until then wait, since the tail may still be in flight.
        guard buffer.count - offset >= total else { break }
        fail(.corruptedFrame(operatorNibble: flags & 0x0F))
        offset += total
        continue
      }

      guard buffer.count - offset >= total else { break }
      let frameBytes = Array(buffer[offset..<(offset + total)])
      offset += total
      do {
        frames.append(try BmapFrame.decode(frameBytes))
      } catch let error as BmapFrameError {
        // The operator was already validated and the length matches by construction,
        // so this is not expected; surface it rather than swallow it.
        fail(.frame(error))
      }
    }

    if offset > 0 {
      buffer.removeFirst(offset)
    }

    // Whatever remains is an incomplete frame awaiting more bytes. If that tail alone
    // exceeds the cap the stream is wedged (or the cap is smaller than one frame), so
    // drop it and report rather than grow without bound.
    if buffer.count > maximumBufferedBytes {
      buffer.removeAll(keepingCapacity: false)
      fail(.bufferOverflow(maximumBufferedBytes))
    }

    if let error = firstError {
      pending = frames
      throw error
    }
    return frames
  }
}

public enum BmapStreamError: Error, Equatable, CustomStringConvertible, Sendable {
  case corruptedFrame(operatorNibble: UInt8)
  case bufferOverflow(Int)
  case frame(BmapFrameError)

  public var description: String {
    switch self {
    case .corruptedFrame(let nibble):
      "corrupted frame skipped: invalid operator nibble \(nibble)"
    case .bufferOverflow(let maximum):
      "buffered bytes exceeded \(maximum) without completing a frame"
    case .frame(let error):
      "frame decode failed: \(error)"
    }
  }
}
