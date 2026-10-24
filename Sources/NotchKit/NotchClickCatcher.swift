import AppKit

/// An invisible window that stands over the closed bar so a press on it lands on us
/// instead of on the menu bar item behind it.
///
/// The strip that draws the bar spans the whole width of the screen, so it cannot take
/// presses while closed without taking every press on the menu bar too; it stays
/// transparent to the mouse, and this window — sized to what the pointer may reach and
/// nothing more — takes them instead. The window server routes a press by frame, so one
/// just past the bar's edge still reaches the menu bar, however far behind the pointer
/// polling happens to be.
///
/// It acts on nothing itself. A press on it reaches the controller through the pointer
/// monitor's local route, like a press on any window of ours, which keeps one path for
/// it: a handler here as well would see the same press twice, opening the panel and
/// closing it again on a single click.
final class NotchClickCatcher: NSPanel {
  private var frameRequest = FrameRequest()

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Above the strip, so the order between the two never depends on which was
    // brought forward last.
    configureAsNotchOverlay(level: NotchWindow.overlayLevel + 1)
    contentView = SwallowingView()
    // Passive until the controller gives it a frame; covering then sets this to false
    // explicitly. Left at the default, a window decides by its pixels' alpha, and
    // fully transparent pixels let presses through — the faint fill in the view makes
    // sure there are none, so the catcher holds whichever rule the window server applies.
    ignoresMouseEvents = true
    // While the pointer is on the catcher, its movement is ours rather than another
    // app's, so the global monitor no longer hears it. Accepting it lets the local
    // monitor hear it instead, rather than leaving the hint to the tenth-second poll.
    acceptsMouseMovedEvents = true
  }

  // Never key: it carries nothing to type into, and the press it takes must not pull
  // the keyboard away from the app the user is working in.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Moves over `frame` and takes presses there, or stands aside when it is nil.
  func cover(_ frame: CGRect?) {
    guard let frame else {
      if !ignoresMouseEvents { ignoresMouseEvents = true }
      return
    }
    place(frame, display: false, request: &frameRequest)
    if ignoresMouseEvents { ignoresMouseEvents = false }
  }
}

/// Takes every press inside it and does nothing with it, so none falls through to a
/// view or window behind. The pointer monitor has already reported the press by the
/// time it is dispatched here.
private final class SwallowingView: NSView {
  /// Black at one percent: nothing anyone can see — under it is the black bar, or a
  /// few points of slack around it — but no pixel left fully transparent.
  private static let fill = NSColor.black.withAlphaComponent(0.01).cgColor

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Self.fill
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer?.backgroundColor = Self.fill
  }

  // The app is almost never active; without this the first press would only be spent
  // on bringing the window forward.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
}
