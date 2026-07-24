import AppKit
import CoreGraphics

/// Posts a system media key — the very event a headset sends natively when the control
/// channel is *not* held. Re-issuing the same key (rather than scripting one particular
/// player) restores a touch gesture's effect for whatever is actually playing: a browser
/// video, a game, any app that answers the keyboard's play/next/previous keys, not only
/// Spotify or Music.
///
/// Posting an event needs no Accessibility permission (only *intercepting* one does), so
/// this adds no new prompt. It is used solely as the fallback for when no scriptable
/// player is playing, so the proven ScriptingBridge path is left exactly as it was.
enum SystemMediaKey {
  case playPause
  case next
  case previous

  /// NX_KEYTYPE_PLAY / _NEXT / _PREVIOUS — the auxiliary key codes the keyboard's
  /// transport keys carry.
  private var keyCode: Int {
    switch self {
    case .playPause: 16
    case .next: 17
    case .previous: 18
    }
  }

  /// Sends the key as a press and release, the way a real key does.
  func post() {
    send(keyDown: true)
    send(keyDown: false)
  }

  private func send(keyDown: Bool) {
    // System-defined auxiliary key events carry the key code and phase in `data1`;
    // 0xA is down and 0xB is up, in both the flags and the low byte.
    let phase = keyDown ? 0xA : 0xB
    let data1 = (keyCode << 16) | (phase << 8)
    guard
      let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(phase << 8)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
      )
    else { return }
    event.cgEvent?.post(tap: .cghidEventTap)
  }
}
