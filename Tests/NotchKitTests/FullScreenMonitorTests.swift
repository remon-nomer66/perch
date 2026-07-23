import AppKit
import Testing

@testable import NotchKit

/// Values shaped like a 14-inch built-in display that is also the primary screen.
/// The window list speaks top-left-origin coordinates, so on this arrangement the
/// screen's top edge is y = 0 there.
private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let ownPID: pid_t = 42

private func windowRow(
  layer: Int, bounds: CGRect, pid: pid_t = 500, alpha: Double = 1
) -> [String: Any] {
  [
    kCGWindowLayer as String: layer,
    kCGWindowOwnerPID as String: pid,
    kCGWindowAlpha as String: alpha,
    kCGWindowBounds as String: bounds.dictionaryRepresentation,
  ]
}

private let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

/// A row shaped like the real menu bar window: full width, at the very top. Inside
/// a full-screen space this window stays listed — visibility is proven only
/// together with a status item.
private func menuBarRow() -> [String: Any] {
  windowRow(layer: menuBarLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 37))
}

private let statusItemLevel = Int(CGWindowLevelForKey(.statusWindow))

/// A row shaped like a real status item (the clock is always one): narrow, in the
/// bar. These leave the window list when the menu bar genuinely hides.
private func statusItemRow() -> [String: Any] {
  windowRow(layer: statusItemLevel, bounds: CGRect(x: 1400, y: 0, width: 40, height: 37))
}

@Test func anOrdinaryDesktopIsNotTaken() {
  // The menu bar at the top, a normal window below it.
  let windows = [
    menuBarRow(),
    statusItemRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aFullScreenWindowWithTheMenuBarGoneIsTaken() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn)
  ]

  #expect(
    FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func splitViewIsCaughtThroughItsWiderPane() {
  // The narrower pane alone would fail the width rule; its wider partner carries the
  // pair over it.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 0, width: 906, height: 982)),
    windowRow(layer: 0, bounds: CGRect(x: 910, y: 0, width: 602, height: 982)),
  ]

  #expect(
    FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aVisibleMenuBarVetoesAWideWindowTouchingTheTop() {
  // An overlay tool's borderless window can be laid over the whole screen while the
  // menu bar stays in plain sight; that is not a takeover, and the bar must not
  // step aside for it.
  let windows = [
    menuBarRow(),
    statusItemRow(),
    windowRow(layer: 0, bounds: builtIn),
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aNarrowOverlayAtTheMenuBarLevelDoesNotPoseAsTheMenuBar() {
  // Third parties do park windows at the menu bar level. A narrow one says nothing
  // about the screen being handed over; only the full-width bar does.
  let windows = [
    windowRow(layer: menuBarLevel, bounds: CGRect(x: 600, y: 0, width: 300, height: 24)),
    windowRow(layer: 0, bounds: builtIn),
  ]

  #expect(
    FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func ourOwnStripWindowDoesNotCountAsATakeover() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn, pid: ownPID)
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aFullyTransparentWindowDoesNotCount() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn, alpha: 0)
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aMaximizedWindowUnderTheVisibleMenuBarDoesNotCount() {
  // Maximized on the desktop: its top edge sits exactly where a letterboxed
  // full-screen window's would, and only the menu bar in plain sight tells the two
  // apart.
  let windows = [
    menuBarRow(),
    statusItemRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aLetterboxedFullScreenWindowIsTaken() {
  // The real shape of full screen on a notched display: the system letterboxes the
  // window below the camera housing, so its top edge is at the safe-area line, not
  // at y = 0 — and the menu bar is gone. Regression: the first shipped rule only
  // looked at the very top of the screen and missed exactly this.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945))
  ]

  #expect(
    FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aWindowWellBelowTheTopBandDoesNotCount() {
  // An ordinary floating window that starts under the top band says nothing about
  // the screen, menu bar or not.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 100, y: 200, width: 1200, height: 700))
  ]

  #expect(
    !FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func aListedMenuBarWithoutStatusItemsDoesNotVeto() {
  // The shape of a real full-screen space, observed live: the menu bar's window
  // stays in the on-screen list — opaque — while its status items leave. The bar's
  // window alone must not read as "visible", or full screen is never detected.
  let windows = [
    menuBarRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(
    FullScreenMonitor.isTaken(
      windows: windows, screenFrame: builtIn, safeAreaTop: 37, primaryFrame: builtIn, ownPID: ownPID
    )
  )
}

@Test func theTopEdgeFlipsThroughThePrimaryScreensHeight() {
  // The notch screen sits beside a taller primary display: its AppKit frame is
  // offset both ways, and its top edge lands mid-way down the flipped coordinates.
  let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
  let screen = CGRect(x: 2560, y: 300, width: 1512, height: 982)
  // Top edge in flipped coordinates: 1440 - (300 + 982) = 158.
  let fullScreen = windowRow(
    layer: 0, bounds: CGRect(x: 2560, y: 158, width: 1512, height: 982)
  )
  let menuBarThere = windowRow(
    layer: menuBarLevel, bounds: CGRect(x: 2560, y: 158, width: 1512, height: 37)
  )
  let statusItemThere = windowRow(
    layer: statusItemLevel, bounds: CGRect(x: 3960, y: 158, width: 40, height: 37)
  )

  #expect(
    FullScreenMonitor.isTaken(
      windows: [fullScreen], screenFrame: screen, safeAreaTop: 37, primaryFrame: primary, ownPID: ownPID
    )
  )
  #expect(
    !FullScreenMonitor.isTaken(
      windows: [menuBarThere, statusItemThere, fullScreen],
      screenFrame: screen,
      safeAreaTop: 37,
      primaryFrame: primary,
      ownPID: ownPID
    )
  )
}
