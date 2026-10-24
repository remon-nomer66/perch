import AppKit
import Testing

@testable import NotchKit

// These build real panels in the test process; none is ever ordered on screen.

private let bar = CGRect(x: 722, y: 1127, width: 356, height: 42)

// MARK: - Catcher

@Test @MainActor func theCatcherFillIsFaintYetClearOfTheTransparencyThreshold() {
  // A pixel with no alpha lets a press through wherever the window server decides by
  // alpha. One percent rounds to 3 of 255 — close enough to nothing to risk it — while
  // the fill must stay invisible over the few points of slack beside the bar.
  let alpha = NotchClickCatcher.fillAlpha

  #expect((alpha * 255).rounded() >= 7)
  #expect(alpha <= 0.03)
}

@Test @MainActor func theCatcherTakesPressesOnlyWhileCovering() {
  let catcher = NotchClickCatcher()
  #expect(catcher.ignoresMouseEvents, "a catcher with no frame yet must take nothing")

  catcher.cover(bar)
  #expect(!catcher.ignoresMouseEvents)

  catcher.cover(nil)
  #expect(catcher.ignoresMouseEvents)
}

@Test @MainActor func theCatcherSitsAboveTheStripInTheSameSpaces() {
  // Above, so the order between the two never depends on which came forward last; in
  // the same spaces, or a catcher would stay behind over a bar that is not there.
  let catcher = NotchClickCatcher()
  let strip = NotchWindow(screenFrame: CGRect(x: 0, y: 909, width: 1800, height: 260))

  #expect(catcher.level.rawValue > strip.level.rawValue)
  #expect(catcher.collectionBehavior == strip.collectionBehavior)
  #expect(!catcher.canBecomeKey)
}

// MARK: - Strip

@Test @MainActor func theStripCanBecomeKeyOnlyWhileInteractive() {
  let strip = NotchWindow(screenFrame: CGRect(x: 0, y: 909, width: 1800, height: 260))
  #expect(!strip.canBecomeKey, "closed, the strip must not be able to take the keyboard")

  strip.setInteractive(true)
  #expect(strip.canBecomeKey)
  #expect(!strip.ignoresMouseEvents)

  strip.setInteractive(false)
  #expect(!strip.canBecomeKey)
  #expect(strip.ignoresMouseEvents)
}
