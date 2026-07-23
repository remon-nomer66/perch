import Foundation
import TandemCore

/// Turns a byte stream into frames without abandoning the rest of a read when one
/// frame is damaged.
///
/// A transport-level parser cannot stop at the first bad frame: the bytes after it
/// are usually intact, and the device keeps sending. Damaged input is dropped,
/// recorded, and the parser resynchronises on the next start byte. Accumulation is
/// bounded so a stream that never delivers an end byte cannot grow without limit.
public struct FrameStreamParser: Sendable {
  public enum Discard: Equatable, Sendable {
    /// The body reached an end byte but failed validation.
    case malformed(TandemFrameError)
    /// No end byte arrived within the maximum frame length.
    case oversized(droppedBytes: Int)
    /// A start byte appeared inside a partially accumulated body.
    case truncated(droppedBytes: Int)
  }

  public struct Output: Equatable, Sendable {
    public var frames: [TandemFrame]
    public var discards: [Discard]

    public init(frames: [TandemFrame] = [], discards: [Discard] = []) {
      self.frames = frames
      self.discards = discards
    }

    public var isEmpty: Bool { frames.isEmpty && discards.isEmpty }
  }

  private enum State: Sendable {
    case waitingForStart
    case body
    case escaped
  }

  public let maximumPayloadLength: Int

  /// Header, declared length, and checksum surrounding the payload.
  private static let frameOverhead = 7

  private var maximumBodyLength: Int { maximumPayloadLength + Self.frameOverhead }

  private var state: State = .waitingForStart
  private var body: [UInt8] = []
  /// Set once the body outgrows the limit. Further bytes are counted but not kept,
  /// so a stream without end bytes costs a counter rather than memory.
  private var droppedWhileOversized = 0

  /// Smallest useful payload, and a ceiling that keeps `maximumBodyLength` from
  /// overflowing however the caller is configured.
  public static let payloadLengthRange = 1...(1 << 24)

  public init(maximumPayloadLength: Int = 65_536) {
    self.maximumPayloadLength = min(
      max(maximumPayloadLength, Self.payloadLengthRange.lowerBound),
      Self.payloadLengthRange.upperBound
    )
  }

  /// Bytes currently held. Never exceeds `maximumBodyLength`; exposed so tests can
  /// check the bound directly instead of inferring it from parser output.
  var retainedByteCount: Int { body.count }

  public mutating func append(_ data: Data) -> Output {
    var output = Output()
    for byte in data {
      switch state {
      case .waitingForStart:
        if byte == TandemFrame.startByte {
          beginBody()
        }

      case .body:
        switch byte {
        case TandemFrame.startByte:
          if let discard = discardPartialBody(as: Discard.truncated) {
            output.discards.append(discard)
          }
          beginBody()
        case TandemFrame.endByte:
          finishBody(into: &output)
        case TandemFrame.escapeByte:
          state = .escaped
        default:
          accumulate(byte)
        }

      case .escaped:
        guard byte == 0x2C || byte == 0x2D || byte == 0x2E else {
          // An oversized body is the more informative failure, so it wins.
          let wasOversized = isOversized
          let dropped = body.count + droppedWhileOversized
          resetBody()
          output.discards.append(
            wasOversized ? .oversized(droppedBytes: dropped) : .malformed(.invalidEscape(byte))
          )
          // The offending byte may itself be a start byte. Consuming it would swallow
          // the frame that follows, so resynchronise on it rather than past it.
          if byte == TandemFrame.startByte {
            beginBody()
          } else {
            state = .waitingForStart
          }
          continue
        }
        accumulate(byte | 0x10)
        state = .body
      }
    }
    return output
  }

  private mutating func beginBody() {
    resetBody()
    state = .body
  }

  private mutating func resetBody() {
    body.removeAll(keepingCapacity: true)
    droppedWhileOversized = 0
  }

  private mutating func accumulate(_ byte: UInt8) {
    guard body.count < maximumBodyLength else {
      // Saturates: an endless stream of junk must cost a counter, not a trap.
      if droppedWhileOversized < Int.max { droppedWhileOversized += 1 }
      return
    }
    body.append(byte)
  }

  private var isOversized: Bool { droppedWhileOversized > 0 }

  private mutating func discardPartialBody(
    as make: (Int) -> Discard
  ) -> Discard? {
    let dropped = body.count + droppedWhileOversized
    let discard = isOversized ? Discard.oversized(droppedBytes: dropped) : make(dropped)
    resetBody()
    return dropped > 0 ? discard : nil
  }

  private mutating func finishBody(into output: inout Output) {
    defer {
      resetBody()
      state = .waitingForStart
    }

    if isOversized {
      output.discards.append(
        .oversized(droppedBytes: body.count + droppedWhileOversized)
      )
      return
    }

    do {
      let frame = try TandemStreamDecoder.decodeBody(
        body,
        maximumPayloadLength: maximumPayloadLength
      )
      output.frames.append(frame)
    } catch let error as TandemFrameError {
      output.discards.append(.malformed(error))
    } catch {
      output.discards.append(.malformed(.frameTooShort(body.count)))
    }
  }
}
