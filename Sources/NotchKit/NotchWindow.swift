import AppKit

/// A borderless window pinned over the notch.
///
/// It floats above the menu bar so the panel is not clipped by it, joins every space
/// so the notch behaves the same wherever the user is, and stays out of the window
/// cycle so it never steals focus from real work.
public final class NotchWindow: NSPanel {
  /// Above the menu bar and its status items, which the panel has to cover.
  static let overlayLevel: NSWindow.Level = .statusBar + 1

  public init(screenFrame: CGRect) {
    super.init(
      contentRect: screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configureAsNotchOverlay(level: Self.overlayLevel)
    // Nothing is interactive until the panel is open, so clicks pass through to the
    // menu bar and status items underneath. A press on the closed bar is taken by the
    // click catcher instead, which covers the bar and nothing else.
    ignoresMouseEvents = true
  }

  public override var canBecomeKey: Bool { true }
  public override var canBecomeMain: Bool { false }

  /// Interactive only while something is on screen to interact with.
  public func setInteractive(_ interactive: Bool) {
    ignoresMouseEvents = !interactive
  }
}

extension NSPanel {
  /// The configuration every window the notch puts up shares, so the strip and the
  /// click catcher cannot drift apart — one joining a space the other does not would
  /// leave a catcher swallowing presses over a bar that is not there.
  func configureAsNotchOverlay(level: NSWindow.Level) {
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    self.level = level
    collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
  }
}
