import CoreGraphics
import Foundation

/// Reads from the window list whether the notch screen has been handed over whole to an
/// app — full screen and Split View alike — kept apart from the live query so it can be
/// exercised against synthetic window lists.
///
/// A normal-level window reaching the top band of the screen — the camera housing row
/// plus the line just under it, where full screen letterboxes its window — is what a
/// takeover looks like. A window maximized under the menu bar reaches the band too, with
/// the very same bounds, so whatever reaches it, the screen counts as taken only while
/// the menu bar is not provably showing. Only window bounds, levels, and alphas are
/// read — none needs the screen-recording permission that window names do.
enum FullScreenRule {
  /// What proves the menu bar visible, which depends on the release (see `readMenuBar`).
  enum MenuBarWitness: Equatable, Sendable {
    /// Through macOS 26: its status items, which leave the list when the bar hides.
    case statusItems
    /// From macOS 27, which lists no status items at all: the desktop under it.
    case desktop

    static let running: MenuBarWitness =
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .desktop : .statusItems
  }

  /// The frames arrive in AppKit coordinates; the window list speaks in top-left-origin
  /// global coordinates. The primary screen anchors both systems, so the screen's top
  /// edge flips through the primary's maxY.
  static func read(
    windows: [[String: Any]],
    screenFrame: CGRect,
    safeAreaTop: CGFloat,
    primaryFrame: CGRect,
    ownPID: pid_t,
    witness: MenuBarWitness
  ) -> FullScreenReading {
    // Full screen on a notched display is letterboxed below the camera housing, so the
    // window that owns the screen tops out at the safe-area line, never at the screen's
    // very top. The strip therefore spans the housing row plus a couple of points below
    // it: deep enough to catch a letterboxed window's top edge.
    let topStrip = CGRect(
      x: screenFrame.minX,
      y: primaryFrame.maxY - screenFrame.maxY,
      width: screenFrame.width,
      height: safeAreaTop + 2
    )
    // None of our own windows can testify about the screen either way.
    let atTop = windows.compactMap(ListedWindow.init).filter {
      $0.pid != ownPID && $0.bounds.intersects(topStrip)
    }
    // Half the screen keeps stray palettes and status items out while still catching
    // the narrower pane of a Split View pair through its wider partner.
    let wide = atTop.filter { $0.bounds.width >= screenFrame.width / 2 }

    guard wide.contains(where: { $0.layer == normalLevel }) else {
      return FullScreenReading(reason: .nothingAtTheTop)
    }
    return readMenuBar(
      atTop: atTop, wide: wide, screenFrame: screenFrame, topStrip: topStrip, witness: witness
    )
  }

  /// The menu bar showing at this screen's top is the strongest sign the screen was
  /// *not* handed over: taking that bar away is precisely what full screen does.
  /// Without it, any wide normal-level window laid over the whole screen (overlay tools,
  /// borderless windows) would read as a takeover with the bar in plain sight.
  ///
  /// The bar's own window proves little alone. It leaves the list when an app hides the
  /// bar outright — a game taking the screen without a space — but inside a full-screen
  /// space it stays listed, opaque, while the bar merely hides. Visible therefore takes a
  /// second witness, one that a full-screen space does not have:
  ///
  /// - Through macOS 26, its status items (the clock is always one), which leave when
  ///   the bar hides.
  /// - From macOS 27, which lists no status items at all — the bar in plain sight or
  ///   not — the desktop under it. A full-screen space shows no desktop, so Finder's
  ///   desktop window and the furniture just above it leave the list, while a takeover
  ///   that makes no space keeps the desktop and loses the bar's window instead.
  ///
  /// Each release consults only its own witness. The desktop would plausibly serve
  /// earlier releases too, but their full-screen spaces were only ever verified by the
  /// status items, and a desktop window lingering there would silently end detection.
  /// On macOS 27, anything at the status level belongs to a third party and may follow
  /// the user into a full-screen space, so it proves nothing about the bar.
  private static func readMenuBar(
    atTop: [ListedWindow],
    wide: [ListedWindow],
    screenFrame: CGRect,
    topStrip: CGRect,
    witness: MenuBarWitness
  ) -> FullScreenReading {
    // A strip, not a sheet: overlays that cover the whole screen at this level stay
    // listed through every state, and a narrow one at the same level cannot pose as the
    // full-width bar either.
    let menuBarListed = wide.contains {
      $0.layer == menuBarLevel && $0.bounds.height < screenFrame.height / 2
    }
    guard menuBarListed else { return FullScreenReading(reason: .menuBarGone) }

    switch witness {
    case .statusItems:
      let listed = atTop.contains { $0.layer == statusItemLevel }
      return FullScreenReading(
        reason: listed ? .menuBarWithStatusItems : .menuBarWithoutStatusItems
      )
    case .desktop:
      // The desktop spans the screen and runs on below the band; the fill laid over the
      // housing row while the bar is hidden sits at a desktop level too, but never does.
      let listed = wide.contains {
        desktopLevels.contains($0.layer) && $0.bounds.maxY > topStrip.maxY
      }
      return FullScreenReading(reason: listed ? .menuBarOverTheDesktop : .menuBarWithoutDesktop)
    }
  }

  private static let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
  private static let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
  private static let statusItemLevel = Int(CGWindowLevelForKey(.statusWindow))
  /// The desktop's own layers: Finder's icons, and the Window Server's furniture above
  /// them up to the backstop beneath every app. The wallpaper sits lower still, and is
  /// left out on purpose — a full-screen space keeps it behind its window.
  private static let desktopLevels =
    Int(CGWindowLevelForKey(.desktopIconWindow))..<Int(CGWindowLevelForKey(.backstopMenu))
}

/// One row of the window list, parsed; nil when a field is missing or the window is
/// fully transparent.
private struct ListedWindow {
  let layer: Int
  let pid: pid_t
  let bounds: CGRect

  init?(_ row: [String: Any]) {
    guard let layer = row[kCGWindowLayer as String] as? Int,
      let pid = row[kCGWindowOwnerPID as String] as? pid_t,
      let alpha = row[kCGWindowAlpha as String] as? Double, alpha > 0,
      let boundsDict = row[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDict)
    else { return nil }
    self.layer = layer
    self.pid = pid
    self.bounds = bounds
  }
}
