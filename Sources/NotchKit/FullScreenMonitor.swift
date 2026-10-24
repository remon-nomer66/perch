import AppKit

/// Watches whether the notch screen has been taken over by a full-screen app — the
/// state in which the menu bar hides itself, and a bar hovering over the content
/// would be unwelcome.
///
/// The window list tells (see `FullScreenRule`). Space changes and app switches re-check
/// at once; a slow poll catches games and players that take the screen without creating
/// a space.
@MainActor
public final class FullScreenMonitor {
  public var onChange: ((Bool) -> Void)?
  public private(set) var isFullScreen = false

  private var observers: [any NSObjectProtocol] = []
  private var poller: Timer?

  public init() {}

  public func start() {
    stop()
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.evaluate() }
        }
      )
    }
    let poller = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.evaluate() }
    }
    RunLoop.main.add(poller, forMode: .common)
    self.poller = poller
    evaluate()
  }

  /// Also reports the screen as no longer taken: whoever stops watching is saying
  /// the answer no longer matters, and a stale "full screen" must not stick.
  public func stop() {
    let center = NSWorkspace.shared.notificationCenter
    observers.forEach { center.removeObserver($0) }
    observers = []
    poller?.invalidate()
    poller = nil
    if isFullScreen {
      isFullScreen = false
      onChange?(false)
    }
  }

  private func evaluate() {
    let taken = Self.readNotchScreen().isTaken
    guard taken != isFullScreen else { return }
    isFullScreen = taken
    onChange?(taken)
  }

  private static func readNotchScreen() -> FullScreenReading {
    guard let screen = NSScreen.withNotch, let primary = NSScreen.screens.first,
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]]
    else { return FullScreenReading(reason: .nothingToRead) }
    return FullScreenRule.read(
      windows: windows,
      screenFrame: screen.frame,
      safeAreaTop: screen.safeAreaInsets.top,
      primaryFrame: primary.frame,
      ownPID: ProcessInfo.processInfo.processIdentifier,
      witness: .running
    )
  }
}
