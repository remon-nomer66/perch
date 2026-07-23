import Foundation

/// The touch-panel notifications heard so far, kept for the support report.
///
/// A headset holding the control channel announces each touch gesture as an
/// action-log frame (`0xC9`, inquiry `0x01`) carrying a short self-describing ASCII
/// name — the operation (`opPlay`) and the physical key (`keyRDoubleTap`). Recording
/// those names is the only way a report can show a model's gesture vocabulary,
/// because they are sent spontaneously and cannot be read on request.
///
/// Only frames that are a single bare ASCII token are kept. The same command also
/// echoes playback state, and a frame carrying free text could hold a track title —
/// exactly the kind of personal detail the report promises to exclude — so anything
/// with spaces, multi-byte text, or unusual length is refused rather than filtered.
public struct TandemGestureNotificationLog: Equatable, Sendable {
  /// Distinct payloads kept before new ones are dropped. The vocabulary is small and
  /// each gesture repeats, so the first distinct frames are the whole story.
  public static let capacity = 24

  /// One capture per distinct payload, in arrival order. The request side is empty:
  /// these were announced, not asked for.
  public private(set) var captures: [TandemRawCapture]

  public init() {
    captures = []
  }

  /// The log with this payload added, or unchanged when the payload is not a
  /// gesture notification, was already heard, or the log is full.
  public func recording(_ payload: Data) -> TandemGestureNotificationLog {
    guard captures.count < Self.capacity else { return self }
    let bytes = [UInt8](payload)
    guard let token = Self.token(in: bytes) else { return self }
    guard !captures.contains(where: { $0.response == bytes }) else { return self }

    var next = self
    next.captures.append(
      TandemRawCapture(label: Self.labelPrefix + token, request: [], response: bytes)
    )
    return next
  }

  /// The gesture names a capture list carries, in arrival order — what a listening
  /// window shows the user as their touches are heard.
  public static func tokens(in captures: [TandemRawCapture]) -> [String] {
    captures
      .filter { $0.label.hasPrefix(labelPrefix) }
      .map { String($0.label.dropFirst(labelPrefix.count)) }
  }

  private static let labelPrefix = "notify."
  private static let command: UInt8 = 0xC9
  private static let actionLogInquiry: UInt8 = 0x01
  private static let maximumLength = 24

  /// The single ASCII token the frame carries, or nil when the frame is not an
  /// action-log notification shaped that way.
  ///
  /// Both known shapes — `C9 01 00 <len> <ascii> 00` and `C9 01 <len> <ascii> 00 00`
  /// — are one run of token characters surrounded by small structural bytes, so the
  /// check is exactly that: after command and inquiry, one contiguous run of
  /// `[A-Za-z0-9_-]` starting with a letter, and nothing else above `0x20`.
  private static func token(in bytes: [UInt8]) -> String? {
    guard bytes.count >= 4, bytes.count <= maximumLength else { return nil }
    guard bytes[0] == command, bytes[1] == actionLogInquiry else { return nil }

    var run: [UInt8] = []
    var finished = false
    for byte in bytes.dropFirst(2) {
      if isTokenCharacter(byte) {
        if finished { return nil }  // a second run: not a bare token
        run.append(byte)
      } else if byte > 0x20 {
        return nil  // printable but not a token character: not a gesture name
      } else if !run.isEmpty {
        finished = true
      }
    }

    guard run.count >= 2, isLetter(run[0]) else { return nil }
    return String(decoding: run, as: UTF8.self)
  }

  private static func isTokenCharacter(_ byte: UInt8) -> Bool {
    isLetter(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
  }

  private static func isLetter(_ byte: UInt8) -> Bool {
    (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
  }
}
