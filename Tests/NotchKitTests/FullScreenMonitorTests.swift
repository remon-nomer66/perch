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
/// together with a status item or the desktop.
private func menuBarRow() -> [String: Any] {
  windowRow(layer: menuBarLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 37))
}

private let statusItemLevel = Int(CGWindowLevelForKey(.statusWindow))

/// A row shaped like a real status item (the clock is always one): narrow, in the
/// bar. These leave the window list when the menu bar genuinely hides.
private func statusItemRow(pid: pid_t = 500) -> [String: Any] {
  windowRow(
    layer: statusItemLevel, bounds: CGRect(x: 1400, y: 0, width: 40, height: 37), pid: pid
  )
}

/// Reads as macOS 14 through 26 do, where the bar's status items prove it visible.
private func readThrough26(
  _ windows: [[String: Any]], screenFrame: CGRect = builtIn, primaryFrame: CGRect = builtIn
) -> FullScreenReading {
  FullScreenRule.read(
    windows: windows,
    screenFrame: screenFrame,
    safeAreaTop: 37,
    primaryFrame: primaryFrame,
    ownPID: ownPID,
    witness: .statusItems,
    hasSeenDesktop: false
  )
}

@Test func anOrdinaryDesktopIsNotTaken() {
  // The menu bar at the top, a normal window below it.
  let windows = [
    menuBarRow(),
    statusItemRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(!readThrough26(windows).isTaken)
}

@Test func aFullScreenWindowWithTheMenuBarGoneIsTaken() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn)
  ]

  #expect(readThrough26(windows).isTaken)
}

@Test func splitViewIsCaughtThroughItsWiderPane() {
  // The narrower pane alone would fail the width rule; its wider partner carries the
  // pair over it.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 0, width: 906, height: 982)),
    windowRow(layer: 0, bounds: CGRect(x: 910, y: 0, width: 602, height: 982)),
  ]

  #expect(readThrough26(windows).isTaken)
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

  #expect(!readThrough26(windows).isTaken)
}

@Test func aNarrowOverlayAtTheMenuBarLevelDoesNotPoseAsTheMenuBar() {
  // Third parties do park windows at the menu bar level. A narrow one says nothing
  // about the screen being handed over; only the full-width bar does.
  let windows = [
    windowRow(layer: menuBarLevel, bounds: CGRect(x: 600, y: 0, width: 300, height: 24)),
    windowRow(layer: 0, bounds: builtIn),
  ]

  #expect(readThrough26(windows).isTaken)
}

@Test func ourOwnStripWindowDoesNotCountAsATakeover() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn, pid: ownPID)
  ]

  #expect(!readThrough26(windows).isTaken)
}

@Test func aFullyTransparentWindowDoesNotCount() {
  let windows = [
    windowRow(layer: 0, bounds: builtIn, alpha: 0)
  ]

  #expect(!readThrough26(windows).isTaken)
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

  #expect(!readThrough26(windows).isTaken)
}

@Test func aLetterboxedFullScreenWindowIsTaken() {
  // The real shape of full screen on a notched display: the system letterboxes the
  // window below the camera housing, so its top edge is at the safe-area line, not
  // at y = 0 — and the menu bar is gone. Regression: the first shipped rule only
  // looked at the very top of the screen and missed exactly this.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945))
  ]

  #expect(readThrough26(windows).isTaken)
}

@Test func aWindowWellBelowTheTopBandDoesNotCount() {
  // An ordinary floating window that starts under the top band says nothing about
  // the screen, menu bar or not.
  let windows = [
    windowRow(layer: 0, bounds: CGRect(x: 100, y: 200, width: 1200, height: 700))
  ]

  #expect(!readThrough26(windows).isTaken)
}

@Test func theMenuBarsWindowAloneDoesNotVeto() {
  // The shape of a real full-screen space before macOS 27, observed live: the menu
  // bar's window stays in the on-screen list — opaque — while its status items leave.
  // The bar's window alone must not read as "visible", or full screen is never detected.
  // (macOS 27 lists no status items even on the desktop, where this shape is an
  // ordinary desktop but for the desktop itself; see the macOS 27 cases below.)
  let windows = [
    menuBarRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(readThrough26(windows).reason == .menuBarWithoutStatusItems)
  #expect(readThrough26(windows).isTaken)
}

@Test func throughMacOS26TheDesktopDoesNotVouchForTheBar() {
  // Before macOS 27, full-screen spaces were only ever verified by their status items,
  // so those releases keep that rule unchanged: the desktop is not consulted there.
  let windows = [
    menuBarRow(),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
    windowRow(layer: Int(CGWindowLevelForKey(.desktopIconWindow)), bounds: builtIn),
  ]

  #expect(readThrough26(windows).isTaken)
}

@Test func ourOwnStatusItemDoesNotProveTheBarVisible() {
  // The app shows a status item of its own when it has no notch to live in; that one
  // says nothing about the bar it sits in.
  let windows = [
    menuBarRow(),
    statusItemRow(pid: ownPID),
    windowRow(layer: 0, bounds: CGRect(x: 0, y: 37, width: 1512, height: 945)),
  ]

  #expect(readThrough26(windows).isTaken)
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

  #expect(readThrough26([fullScreen], screenFrame: screen, primaryFrame: primary).isTaken)
  #expect(
    !readThrough26(
      [menuBarThere, statusItemThere, fullScreen], screenFrame: screen, primaryFrame: primary
    ).isTaken
  )
}

@Test func theTopEdgeFlipsForAScreenAboveThePrimary() {
  // The notch screen sits above the primary display, so its top edge lies above the
  // origin of the flipped coordinates: 1440 - (1440 + 982) = -982.
  let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
  let screen = CGRect(x: 0, y: 1440, width: 1512, height: 982)
  let fullScreen = windowRow(
    layer: 0, bounds: CGRect(x: 0, y: -982, width: 1512, height: 982)
  )
  // The primary's own maximized window, right under its menu bar: not this screen's.
  let belowOnThePrimary = windowRow(
    layer: 0, bounds: CGRect(x: 0, y: 25, width: 2560, height: 1415)
  )

  #expect(readThrough26([fullScreen], screenFrame: screen, primaryFrame: primary).isTaken)
  #expect(
    !readThrough26([belowOnThePrimary], screenFrame: screen, primaryFrame: primary).isTaken
  )
}

// MARK: - macOS 27

/// Values measured live on a 16-inch built-in display under macOS 27: the menu bar is
/// one point deeper than the safe area, so a maximized window starts one point inside
/// the top band — exactly where full screen letterboxes its window.
private let builtIn16 = CGRect(x: 0, y: 0, width: 1800, height: 1169)
private let builtIn16SafeTop: CGFloat = 38
private let windowServerPID: pid_t = 300
private let finderPID: pid_t = 301
private let wallpaperPID: pid_t = 302
private let fullScreenPID: pid_t = 600

private let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
private let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

/// The menu bar's own window as macOS 27 lists it, on the desktop and inside a
/// full-screen space alike.
private func menuBar27() -> [String: Any] {
  windowRow(
    layer: menuBarLevel, bounds: CGRect(x: 0, y: 0, width: 1800, height: 39), pid: windowServerPID
  )
}

/// A window maximized under the menu bar — and, to the window list, a letterboxed
/// full-screen window too: both have exactly these bounds.
private func maximized27(pid: pid_t = 500) -> [String: Any] {
  windowRow(layer: 0, bounds: CGRect(x: 0, y: 39, width: 1800, height: 1130), pid: pid)
}

/// Finder's desktop: on screen wherever the desktop is, gone inside a full-screen space.
private func finderDesktop27() -> [String: Any] {
  windowRow(layer: desktopIconLevel, bounds: builtIn16, pid: finderPID)
}

/// The wallpaper, which a full-screen space keeps behind its window.
private func wallpaper27() -> [String: Any] {
  windowRow(layer: desktopLevel - 1, bounds: builtIn16, pid: wallpaperPID)
}

/// The Window Server's desktop layer just above the icons, as deep as the menu bar's
/// translucent backdrop reaches.
private func underbelly27() -> [String: Any] {
  windowRow(
    layer: desktopIconLevel + 1, bounds: CGRect(x: 0, y: 0, width: 1800, height: 99),
    pid: windowServerPID
  )
}

/// What the Window Server lays over the housing row while the bar is hidden.
private func housingRowFill27() -> [String: Any] {
  windowRow(
    layer: desktopIconLevel + 1, bounds: CGRect(x: 0, y: 0, width: 1800, height: 38),
    pid: windowServerPID
  )
}

/// Reads as macOS 27 does, where the desktop under the bar proves it visible — by
/// default on a screen whose desktop has been seen before, so its absence means
/// something.
private func read27(
  _ windows: [[String: Any]], hasSeenDesktop: Bool = true
) -> FullScreenReading {
  FullScreenRule.read(
    windows: windows,
    screenFrame: builtIn16,
    safeAreaTop: builtIn16SafeTop,
    primaryFrame: builtIn16,
    ownPID: ownPID,
    witness: .desktop,
    hasSeenDesktop: hasSeenDesktop
  )
}

@Test func aMaximizedWindowOnTheMacOS27DesktopIsNotTaken() {
  // Regression: macOS 27 lists no status items at all, even with the menu bar in plain
  // sight, so the old proof of a visible bar never held, and a window maximized under it
  // hid the notch from launch onward. The desktop under the bar proves it instead.
  let windows = [
    menuBar27(),
    maximized27(),
    finderDesktop27(),
    wallpaper27(),
  ]

  #expect(read27(windows).reason == .menuBarOverTheDesktop)
  #expect(!read27(windows).isTaken)
}

@Test func theMacOS27FullScreenSpaceIsTaken() {
  // As observed live: the bar's window stays listed and the window is letterboxed to
  // the very bounds a maximized one has, but the desktop is gone. A backdrop and the
  // wallpaper sit behind the window instead, and its title bar strip waits,
  // transparent, for the pointer.
  let windows = [
    windowRow(layer: 1001, bounds: CGRect(x: 0, y: 39, width: 1, height: 1)),
    menuBar27(),
    windowRow(
      layer: 0, bounds: CGRect(x: 0, y: 39, width: 1800, height: 32), pid: fullScreenPID, alpha: 0
    ),
    maximized27(pid: fullScreenPID),
    windowRow(layer: desktopLevel + 1, bounds: builtIn16, pid: wallpaperPID),
    wallpaper27(),
    windowRow(layer: desktopLevel - 3, bounds: builtIn16, pid: windowServerPID),
  ]

  #expect(read27(windows).reason == .menuBarWithoutDesktop)
  #expect(read27(windows).isTaken)
}

@Test func aTakeoverWithoutASpaceIsTakenOverTheDesktop() {
  // A game hiding the menu bar from a borderless window, as observed live: no space is
  // made, so the desktop stays listed beneath it, but the bar's window leaves the list
  // and the Window Server fills the housing row instead. With the bar gone, the desktop
  // under it proves nothing.
  let windows = [
    windowRow(layer: 0, bounds: builtIn16, pid: fullScreenPID),
    maximized27(),
    housingRowFill27(),
    underbelly27(),
    finderDesktop27(),
    wallpaper27(),
  ]

  #expect(read27(windows).reason == .menuBarGone)
  #expect(read27(windows).isTaken)
}

@Test func aSheetAtTheMenuBarLevelDoesNotPoseAsTheMenuBar() {
  // Seen live: a system overlay covering the whole screen at the menu bar's level stayed
  // listed through every state. It is not the bar, so it must not prove the bar visible
  // while a game holds the screen over the desktop.
  let windows = [
    windowRow(layer: menuBarLevel, bounds: builtIn16, pid: 700),
    windowRow(layer: 0, bounds: builtIn16, pid: fullScreenPID),
    finderDesktop27(),
    wallpaper27(),
  ]

  #expect(read27(windows).isTaken)
}

@Test func theDesktopLayerAboveTheIconsAlsoWitnessesTheDesktop() {
  // Finder's window is not the only desktop furniture a full-screen space leaves
  // behind: the Window Server's own layer just above the icons leaves too, and it does
  // not depend on the user keeping icons on the desktop.
  let windows = [
    menuBar27(),
    maximized27(),
    underbelly27(),
    wallpaper27(),
  ]

  #expect(!read27(windows).isTaken)
}

@Test func theHousingRowFillIsNotTheDesktop() {
  // The fill over the housing row lives at a desktop level but never reaches below the
  // band; it says nothing about the desktop being there.
  let windows = [
    menuBar27(),
    maximized27(pid: fullScreenPID),
    housingRowFill27(),
  ]

  #expect(read27(windows).isTaken)
}

@Test func aNarrowWindowAtTheDesktopLevelIsNotTheDesktop() {
  // Desktop widgets park small windows among the icons; only something spanning the
  // screen stands for the desktop itself.
  let windows = [
    menuBar27(),
    maximized27(pid: fullScreenPID),
    windowRow(layer: desktopIconLevel, bounds: CGRect(x: 20, y: 20, width: 320, height: 320)),
  ]

  #expect(read27(windows).isTaken)
}

@Test func aWideWindowAboveTheDesktopLayersIsNotTheDesktop() {
  // From the backstop up, a window belongs to the apps, not to the desktop.
  let windows = [
    menuBar27(),
    maximized27(pid: fullScreenPID),
    windowRow(layer: Int(CGWindowLevelForKey(.backstopMenu)), bounds: builtIn16),
  ]

  #expect(read27(windows).isTaken)
}

@Test func onMacOS27AWindowAtTheStatusLevelSaysNothingAboutTheBar() {
  // macOS 27 lists no status items of its own, so anything at that level belongs to a
  // third party — and may well follow the user into a full-screen space.
  let windows = [
    menuBar27(),
    windowRow(layer: statusItemLevel, bounds: CGRect(x: 1600, y: 0, width: 40, height: 39)),
    maximized27(pid: fullScreenPID),
    wallpaper27(),
  ]

  #expect(read27(windows).isTaken)
}

// MARK: - Remembering the desktop

@Test func withNoDesktopEverSeenItsAbsenceProvesNothing() {
  // Finder's desktop switched off, or Finder not running: this Mac lists no desktop
  // windows at all, so their absence is its ordinary state, not a full-screen space.
  let windows = [
    menuBar27(),
    maximized27(),
    wallpaper27(),
  ]

  #expect(read27(windows, hasSeenDesktop: false).reason == .desktopNeverSeen)
  #expect(!read27(windows, hasSeenDesktop: false).isTaken)
}

@Test func onceTheDesktopHasBeenSeenItsAbsenceIsAFullScreenSpace() {
  let windows = [
    menuBar27(),
    maximized27(pid: fullScreenPID),
    wallpaper27(),
  ]

  #expect(read27(windows, hasSeenDesktop: true).reason == .menuBarWithoutDesktop)
  #expect(read27(windows, hasSeenDesktop: true).isTaken)
}

@Test func theDesktopIsReportedWhateverTheVerdict() {
  // The record of a seen desktop has to start somewhere: an empty desktop with nothing
  // reaching the top band shows it as plainly as one under a maximized window.
  let emptyDesktop = [menuBar27(), finderDesktop27(), wallpaper27()]
  let game = [windowRow(layer: 0, bounds: builtIn16, pid: fullScreenPID), finderDesktop27()]
  let fullScreenSpace = [menuBar27(), maximized27(pid: fullScreenPID), wallpaper27()]

  #expect(read27(emptyDesktop, hasSeenDesktop: false).reason == .nothingAtTheTop)
  #expect(read27(emptyDesktop, hasSeenDesktop: false).showsDesktop)
  #expect(read27(game).showsDesktop)
  #expect(!read27(fullScreenSpace).showsDesktop)
}

/// Hands the reader one prepared look at the screen per reading.
@MainActor
private final class LookScript {
  private var remaining: [NotchScreenReader.Look]

  init(_ looks: [NotchScreenReader.Look]) {
    remaining = looks
  }

  func next() -> NotchScreenReader.Look? {
    remaining.isEmpty ? nil : remaining.removeFirst()
  }
}

private func look27(
  _ windows: [[String: Any]], screenFrame: CGRect = builtIn16
) -> NotchScreenReader.Look {
  NotchScreenReader.Look(
    windows: windows,
    screenFrame: screenFrame,
    safeAreaTop: builtIn16SafeTop,
    primaryFrame: screenFrame
  )
}

private func desktopLook27() -> NotchScreenReader.Look {
  look27([menuBar27(), maximized27(), finderDesktop27(), wallpaper27()])
}

private func fullScreenLook27() -> NotchScreenReader.Look {
  look27([menuBar27(), maximized27(pid: fullScreenPID), wallpaper27()])
}

@MainActor
@Test func theReaderTrustsTheDesktopsAbsenceOnlyAfterSeeingIt() {
  // Launched straight into a full-screen space, the reader cannot yet tell it from a
  // Mac without desktop windows; one glimpse of the desktop settles which this is.
  let script = LookScript([fullScreenLook27(), desktopLook27(), fullScreenLook27()])
  let reader = NotchScreenReader(look: script.next, ownPID: ownPID, witness: .desktop)

  #expect(reader.read().reason == .desktopNeverSeen)
  #expect(reader.read().reason == .menuBarOverTheDesktop)
  #expect(reader.read().reason == .menuBarWithoutDesktop)
}

@MainActor
@Test func anotherScreenFrameDiscardsTheSeenDesktop() {
  // A changed frame is another screen — or the same one rearranged — whose desktop is
  // yet to be seen.
  let otherFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
  let fullScreenThere = look27(
    [
      windowRow(layer: menuBarLevel, bounds: CGRect(x: 0, y: 0, width: 1512, height: 39)),
      windowRow(
        layer: 0, bounds: CGRect(x: 0, y: 39, width: 1512, height: 943), pid: fullScreenPID
      ),
    ],
    screenFrame: otherFrame
  )
  let script = LookScript([desktopLook27(), fullScreenThere, fullScreenLook27()])
  let reader = NotchScreenReader(look: script.next, ownPID: ownPID, witness: .desktop)

  #expect(reader.read().reason == .menuBarOverTheDesktop)
  #expect(reader.read().reason == .desktopNeverSeen)
  // Back on the first frame, the earlier sighting is gone with the change.
  #expect(reader.read().reason == .desktopNeverSeen)
}

@MainActor
@Test func theReaderHasNothingToReadWithoutANotchScreen() {
  let reader = NotchScreenReader(look: { nil }, ownPID: ownPID, witness: .desktop)

  #expect(reader.read().reason == .nothingToRead)
}

// MARK: - Reporting

private let takenReading = FullScreenReading(reason: .menuBarWithoutDesktop)
private let releasedReading = FullScreenReading(reason: .menuBarOverTheDesktop)

/// Stands in for the screen and the clock: one prepared reading per look, and a time that
/// moves only when the test lets it.
@MainActor
private final class ScreenScript {
  private var remaining: [FullScreenReading]
  private var time: TimeInterval = 100

  init(_ readings: [FullScreenReading]) {
    remaining = readings
  }

  /// "Nothing at the top" once the script runs out, so an extra read cannot trap.
  func next() -> FullScreenReading {
    remaining.isEmpty ? FullScreenReading(reason: .nothingAtTheTop) : remaining.removeFirst()
  }

  func now() -> TimeInterval { time }

  func wait(_ seconds: TimeInterval) {
    time += seconds
  }
}

@MainActor
private func monitor(_ script: ScreenScript) -> FullScreenMonitor {
  FullScreenMonitor(read: script.next, now: script.now)
}

@MainActor
@Test func theMonitorReportsATakeoverOnlyOnceConfirmed() {
  let script = ScreenScript([takenReading, takenReading, releasedReading])
  let subject = monitor(script)
  var reports: [Bool] = []
  subject.onChange = { reports.append($0) }

  subject.evaluate()
  #expect(reports.isEmpty, "a single taken reading moved the notch")
  #expect(subject.isFollowUpPending, "nothing will look again before the slow poll")

  script.wait(FullScreenHysteresis.settleTime)
  subject.evaluate()
  #expect(reports == [true])
  #expect(subject.isFullScreen)

  subject.evaluate()
  #expect(reports == [true, false], "the release waited for confirmation")
  subject.stop()
}

@MainActor
@Test func readingsTakenAtTheSameMomentDoNotConfirmEachOther() {
  // A space change and the app switch it causes arrive together, and both read the
  // same half-finished slide. Only a reading taken later can confirm the first.
  let script = ScreenScript([takenReading, takenReading, takenReading])
  let subject = monitor(script)
  var reports: [Bool] = []
  subject.onChange = { reports.append($0) }

  subject.evaluate()
  script.wait(0.003)
  subject.evaluate()
  #expect(reports.isEmpty)
  #expect(subject.isFollowUpPending)

  script.wait(FullScreenHysteresis.settleTime)
  subject.evaluate()
  #expect(reports == [true])
  subject.stop()
}

@MainActor
@Test func stoppingReleasesTheScreenAndForgetsWhatItSaw() {
  let script = ScreenScript([takenReading, takenReading, takenReading])
  let subject = monitor(script)
  var reports: [Bool] = []
  subject.onChange = { reports.append($0) }
  subject.evaluate()
  script.wait(FullScreenHysteresis.settleTime)
  subject.evaluate()

  subject.stop()
  #expect(reports == [true, false])
  #expect(!subject.isFullScreen)

  // Watching again starts from nothing: one taken reading is not enough, and stopping
  // takes the pending look with it.
  script.wait(FullScreenHysteresis.settleTime)
  subject.evaluate()
  #expect(reports == [true, false])
  subject.stop()
  #expect(!subject.isFollowUpPending)
}
