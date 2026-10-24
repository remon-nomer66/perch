import AppKit

/// A borderless window pinned over the notch.
///
/// It floats above the menu bar so the panel is not clipped by it, joins every space
/// so the notch behaves the same wherever the user is, and stays out of the window
/// cycle so it never steals focus from real work.
public final class NotchWindow: NSPanel {
  /// Above the menu bar and its status items, which the panel has to cover.
  static let overlayLevel: NSWindow.Level = .statusBar + 1

  private var frameRequest = FrameRequest()

  public init(screenFrame: CGRect) {
    super.init(
      contentRect: screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    frameRequest.record(asked: screenFrame, settled: frame)
    configureAsNotchOverlay(level: Self.overlayLevel)
    // Nothing is interactive until the panel is open, so clicks pass through to the
    // menu bar and status items underneath. A press on the closed bar is taken by the
    // click catcher instead, which covers the bar and nothing else.
    ignoresMouseEvents = true
  }

  /// Moves the strip to `frame` unless that is where it was last asked to be.
  func place(_ frame: CGRect, display: Bool) {
    place(frame, display: display, request: &frameRequest)
  }

  /// Only while open. The panel takes the keyboard when a control in it is clicked —
  /// a non-activating panel can, without bringing the app forward — and a strip that
  /// could still become key while closed would hold the keyboard from an invisible window.
  public override var canBecomeKey: Bool { !ignoresMouseEvents }
  public override var canBecomeMain: Bool { false }

  /// Interactive only while something is on screen to interact with. Leaving that state
  /// also hands the keyboard back: nothing else would, and typing would keep landing
  /// in a transparent strip until the user clicked their own window again.
  public func setInteractive(_ interactive: Bool) {
    if ignoresMouseEvents == interactive { ignoresMouseEvents = !interactive }
    guard !interactive, isKeyWindow else { return }
    // On the next pass of the run loop, not inside the event that closed the panel —
    // that may be a press on a control in this very window, still being dispatched.
    DispatchQueue.main.async { [weak self] in self?.relinquishKey() }
  }

  /// Ordering out passes key status to the window behind — for a non-activating panel,
  /// back to the app the user was typing in — and ordering straight back in keeps the
  /// closed bar on screen. Not interactive by now, the strip refuses key on the way
  /// back. Checked again here: the panel may have been reopened in the meantime.
  private func relinquishKey() {
    guard ignoresMouseEvents, isKeyWindow else { return }
    orderOut(nil)
    orderFrontRegardless()
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

  /// Sets `frame` only when `request` says it is not already in place; see
  /// `FrameRequest` for why the window's own `frame` cannot be the comparison.
  func place(_ frame: CGRect, display: Bool, request: inout FrameRequest) {
    guard request.needsPlacing(frame, current: self.frame) else { return }
    setFrame(frame, display: display)
    request.record(asked: frame, settled: self.frame)
  }
}
