import AppKit

/// Watches whether the notch screen has been taken over by a full-screen app — the
/// state in which the menu bar hides itself, and a bar hovering over the content
/// would be unwelcome.
///
/// Full screen is read from the window list: a normal-level window reaching the top
/// band of the screen — the camera housing row plus the line just under it, where
/// full screen letterboxes its window — while the menu bar is nowhere to be seen
/// means the screen was handed over whole (full screen and Split View alike). While
/// the menu bar is showing, nothing was handed over, whatever else reaches the band.
/// Space changes and app switches re-check at once; a
/// slow poll catches games and players that take the screen without creating a space.
/// Only window bounds, levels, and alphas are read — none needs the screen-recording
/// permission that window names do.
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
    let taken = Self.isTakenFullScreen(NSScreen.withNotch)
    guard taken != isFullScreen else { return }
    isFullScreen = taken
    onChange?(taken)
  }

  private static func isTakenFullScreen(_ screen: NSScreen?) -> Bool {
    guard let screen, let primary = NSScreen.screens.first,
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    return isTaken(
      windows: windows,
      screenFrame: screen.frame,
      safeAreaTop: screen.safeAreaInsets.top,
      primaryFrame: primary.frame,
      ownPID: ProcessInfo.processInfo.processIdentifier
    )
  }

  /// The rule itself, separated from the live query so it can be exercised against
  /// synthetic window lists.
  ///
  /// The frames arrive in AppKit coordinates; the window list speaks in
  /// top-left-origin global coordinates. The primary screen anchors both systems, so
  /// the screen's top edge flips through the primary's maxY.
  nonisolated static func isTaken(
    windows: [[String: Any]],
    screenFrame: CGRect,
    safeAreaTop: CGFloat,
    primaryFrame: CGRect,
    ownPID: pid_t
  ) -> Bool {
    // Full screen on a notched display is letterboxed below the camera housing, so
    // the window that owns the screen tops out at the safe-area line, never at the
    // screen's very top. The strip therefore spans the housing row plus a couple of
    // points below it: deep enough to catch a letterboxed window's top edge — which
    // is also where an ordinary maximized window sits, so the menu bar veto below is
    // what separates the two.
    let topStrip = CGRect(
      x: screenFrame.minX,
      y: primaryFrame.maxY - screenFrame.maxY,
      width: screenFrame.width,
      height: safeAreaTop + 2
    )

    // The menu bar showing at this screen's top is the strongest sign the screen was
    // *not* handed over: taking that bar away is precisely what full screen does.
    // Without this signal, any wide normal-level window laid over the whole screen
    // (overlay tools, borderless windows, the Dock's own desktop backdrop) would
    // read as a takeover even with the menu bar in plain sight.
    //
    // "Showing" needs two window levels, both permission free. The bar's own window
    // (kCGMainMenuWindowLevel, full width so a third party's narrow overlay at the
    // same level cannot pose as it) stays in the on-screen list — opaque — even
    // inside a full-screen space, so on its own it proves nothing. Its status items
    // (kCGStatusWindowLevel: the clock is always one) do leave the list when the
    // bar genuinely hides, and that departure is the observable difference between
    // a visible bar and a full-screen space. Only both together count as visible;
    // then the width rule below decides, which is the state the feature exists for:
    // the menu bar hides, and ours follows it out of the way.
    let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    let statusItemLevel = Int(CGWindowLevelForKey(.statusWindow))
    var menuBarWindowListed = false
    var statusItemListed = false
    var takenByWindow = false
    for row in windows {
      guard let window = visibleWindow(row), window.bounds.intersects(topStrip)
      else { continue }
      // Status items are narrow by nature; the bar itself and a takeover are wide.
      // Half the screen keeps stray palettes out while still catching the narrower
      // pane of a Split View pair through its wider partner.
      let isWide = window.bounds.width >= screenFrame.width / 2
      if window.layer == statusItemLevel, window.pid != ownPID { statusItemListed = true }
      guard isWide else { continue }
      if window.layer == menuBarLevel { menuBarWindowListed = true }
      if window.layer == 0, window.pid != ownPID { takenByWindow = true }
    }
    return takenByWindow && !(menuBarWindowListed && statusItemListed)
  }

  /// One row of the window list, parsed; nil when a field is missing or the window
  /// is fully transparent.
  private nonisolated static func visibleWindow(
    _ window: [String: Any]
  ) -> (layer: Int, pid: pid_t, bounds: CGRect)? {
    guard let layer = window[kCGWindowLayer as String] as? Int,
      let pid = window[kCGWindowOwnerPID as String] as? pid_t,
      let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
      let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDict)
    else { return nil }
    return (layer, pid, bounds)
  }
}
