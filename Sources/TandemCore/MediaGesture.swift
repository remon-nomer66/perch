import Foundation

/// A transport action a headset announces over the control channel when the wearer
/// uses the touch panel.
///
/// While any app holds the control channel open, the headset stops emitting these as
/// Bluetooth media keys and instead reports them here — by a short ASCII name it picks
/// itself (`opPlay`, `opNext`, …). Reading that self-describing name, rather than a
/// per-model byte, is what keeps this universal: a model that names its actions the
/// same way is understood without being listed anywhere.
public enum TandemMediaGesture: Equatable, Sendable {
  case play
  case pause
  case next
  case previous
  case volumeUp
  case volumeDown

  /// Decodes the operation a notification frame announces, or nil when the frame is
  /// not one — playback-state echoes, physical-key labels, and volume-level reports
  /// all return nil so nothing acts on them by mistake.
  public static func decode(payload: Data) -> TandemMediaGesture? {
    let bytes = [UInt8](payload)
    // The operation family is `C9 01 00 <len> <ascii> 00`. The headset also sends a
    // physical-key label for the same gesture using the same command but a non-zero
    // third byte (the label's length). Requiring 0x00 there selects the operation
    // alone, so one gesture is never counted twice.
    guard bytes.count >= 5, bytes[0] == 0xC9, bytes[1] == 0x01, bytes[2] == 0x00 else {
      return nil
    }
    let length = Int(bytes[3])
    guard length > 0, bytes.count >= 4 + length else { return nil }
    guard let name = String(bytes: bytes[4..<(4 + length)], encoding: .utf8) else { return nil }
    return operations[name]
  }

  private static let operations: [String: TandemMediaGesture] = [
    "opPlay": .play,
    "opPause": .pause,
    "opNext": .next,
    "opPrev": .previous,
    "opVolUp": .volumeUp,
    "opVolDown": .volumeDown,
  ]

  /// Whether the app must carry this out. The headset applies volume itself even while
  /// the channel is held open, so re-issuing it would double the change; transport is
  /// the part the headset withholds, so only that is forwarded to the player.
  public var isTransport: Bool {
    switch self {
    case .play, .pause, .next, .previous: true
    case .volumeUp, .volumeDown: false
    }
  }
}
