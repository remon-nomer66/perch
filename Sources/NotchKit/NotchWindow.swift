import AppKit

/// A borderless window pinned over the notch.
///
/// It floats above the menu bar so the panel is not clipped by it, joins every space
/// so the notch behaves the same wherever the user is, and stays out of the window
/// cycle so it never steals focus from real work.
public final class NotchWindow: NSPanel {
  public init(screenFrame: CGRect) {
    super.init(
      contentRect: screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    level = .statusBar + 1
    collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    // Nothing is interactive until the pointer is actually on the notch, so clicks
    // pass through to the menu bar and status items underneath.
    ignoresMouseEvents = true
  }

  public override var canBecomeKey: Bool { true }
  public override var canBecomeMain: Bool { false }

  /// Interactive only while something is on screen to interact with.
  public func setInteractive(_ interactive: Bool) {
    ignoresMouseEvents = !interactive
  }
}
