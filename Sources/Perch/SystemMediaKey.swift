import AppKit
import ApplicationServices
import CoreGraphics

/// Posts a system media key — the very event a headset sends natively when the control
/// channel is *not* held. Re-issuing the same key (rather than scripting one particular
/// player) restores a touch gesture's effect for whatever is actually playing: a browser
/// video, a game, any app that answers the keyboard's play/next/previous keys.
///
/// macOS silently drops injected HID events from a process that is not trusted for
/// Accessibility, so the first use asks for that trust with the system's own prompt —
/// a dropped tap with no visible reason would otherwise read as "the button is broken".
/// This path is only the fallback for when no scriptable player has a track; the proven
/// ScriptingBridge path needs no such permission and is preferred whenever it applies.
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

  /// Whether the trust prompt was already raised this launch. The system dialog is
  /// modal enough that raising it on every tap would punish the user for macOS's
  /// silence; once per run states the need without nagging.
  @MainActor private static var promptedForTrust = false

  /// Asks for Accessibility trust the first time it is needed, with the system's own
  /// consent dialog. Returns whether the process is trusted right now — a just-granted
  /// trust applies to later taps without a relaunch.
  @MainActor
  @discardableResult
  static func requestTrustIfNeeded() -> Bool {
    if AXIsProcessTrusted() { return true }
    guard !promptedForTrust else { return false }
    promptedForTrust = true
    // The kAXTrustedCheckOptionPrompt global is a mutable C `var`, which Swift 6's
    // concurrency checking refuses to touch; its documented value is this literal.
    let options = ["AXTrustedCheckOptionPrompt": true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
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
