import Foundation

/// Names for the equaliser preset identifiers a device lists.
///
/// Devices report identifiers without names, whatever display language is requested,
/// so the names have to come from somewhere else. These are taken from the protocol
/// documentation of `andreabedini/soundconnectd` rather than guessed from behaviour;
/// see `THIRD_PARTY_NOTICES.md`.
///
/// An identifier that is not listed keeps its number. Inventing a plausible name for
/// an unknown preset would be worse than admitting we do not know what it does.
public enum TandemEqualizerPresetNames {
  public static func name(for identifier: UInt8) -> String? {
    known[identifier]
  }

  /// Displayable label: the documented name, or the raw identifier.
  public static func label(for identifier: UInt8) -> String {
    known[identifier] ?? String(format: "0x%02X", identifier)
  }

  private static let known: [UInt8: String] = [
    0x00: "オフ",

    0x01: "Rock",
    0x02: "Pop",
    0x03: "Jazz",
    0x04: "Dance",
    0x05: "EDM",
    0x06: "R&B / Hip Hop",
    0x07: "Acoustic",

    0x10: "Bright",
    0x11: "Excited",
    0x12: "Mellow",
    0x13: "Relaxed",
    0x14: "Vocal",
    0x15: "Treble",
    0x16: "Bass",
    0x17: "Speech",

    0x20: "ゲーム",
    0x21: "FPS 1",
    0x22: "FPS 2",
    0x23: "FPS 3",

    0x30: "Heavy",
    0x31: "Clear",
    0x32: "Hard",
    0x33: "Soft",

    0xA0: "カスタム",
    0xA1: "ユーザー 1",
    0xA2: "ユーザー 2",
    0xA3: "ユーザー 3",
    0xA4: "ユーザー 4",
    0xA5: "ユーザー 5",
  ]
}

extension TandemEqualizerCapability {
  /// Steps run from zero; the middle one is flat. A device with 13 steps therefore
  /// spans -6 to +6.
  public var flatStep: Int { max(levelStepCount - 1, 0) / 2 }

  /// The step expressed the way it is shown to a listener, in decibels either side of
  /// flat.
  public func decibels(forStep step: Int) -> Int { step - flatStep }
}
