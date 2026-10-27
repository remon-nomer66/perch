import CoreGraphics
import Testing

@testable import NotchKit

/// Values shaped like a 14-inch built-in display and its notch.
private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let notch = CGRect(x: 620, y: 950, width: 272, height: 32)

// MARK: - Strip

@Test func theStripCoversOnlyTheTopOfTheScreen() {
  let strip = NotchController.stripRect(screenFrame: builtIn, expandedHeight: 200)

  #expect(strip == CGRect(x: 0, y: 982 - 260, width: 1512, height: 260))
}

@Test func aTallerPanelNeedsATallerStrip() {
  // The expanded height is adjustable while the window is up; the strip must grow
  // with it, or the panel is clipped at the window's bottom edge.
  let short = NotchController.stripRect(screenFrame: builtIn, expandedHeight: 120)
  let tall = NotchController.stripRect(screenFrame: builtIn, expandedHeight: 420)

  #expect(tall.height - short.height == 300)
  #expect(short.maxY == builtIn.maxY)
  #expect(tall.maxY == builtIn.maxY)
}

@Test func theStripFollowsAScreenWhoseOriginIsNotZero() {
  // An external display arranged below-left pushes the built-in screen's origin
  // away from zero; the strip must stay glued to that screen, not to the origin.
  let shifted = CGRect(x: -1512, y: 300, width: 1512, height: 982)
  let strip = NotchController.stripRect(screenFrame: shifted, expandedHeight: 200)

  #expect(strip == CGRect(x: -1512, y: 300 + 982 - 260, width: 1512, height: 260))
}

// MARK: - Hover target

@Test func theHoverTargetIsTheWidenedBarWhileItIsVisible() {
  let target = NotchController.hoverTarget(
    barVisible: true, presentation: .closed, notch: notch, isVirtual: false,
    appearance: .default
  )

  #expect(target == NotchAppearance.default.closedRect(around: notch))
}

@Test func theHoverTargetShrinksToTheBareCutoutWhileTheBarIsHidden() {
  // With the bar hidden there is nothing beside the cutout to point at; the side
  // reaches of the invisible bar must not react to the pointer.
  let target = NotchController.hoverTarget(
    barVisible: false, presentation: .closed, notch: notch, isVirtual: false,
    appearance: .default
  )

  #expect(target == notch)
}

@Test func theHoverTargetForAVirtualNotchAtRestIsItsSliver() {
  // At rest, with nothing to announce, a virtual notch is only the sliver: that and
  // nothing larger is what the pointer must reach to wake it.
  let target = NotchController.hoverTarget(
    barVisible: false, presentation: .closed, notch: notch, isVirtual: true,
    appearance: .default
  )

  #expect(target == NotchAppearance.default.restingSliver(in: notch))
}

@Test func theHoverTargetForAVirtualNotchFollowsWhatIsDrawn() {
  // Popping, the virtual notch is drawn at the full cutout — or at the bar once it
  // has something to carry — and the pointer anywhere on that keeps it awake. A
  // target left at the sliver closed it the moment the pointer moved down into the
  // drawn bar, and a click there then fell on nothing.
  let bare = NotchController.hoverTarget(
    barVisible: false, presentation: .popping, notch: notch, isVirtual: true,
    appearance: .default
  )
  let widened = NotchController.hoverTarget(
    barVisible: true, presentation: .popping, notch: notch, isVirtual: true,
    appearance: .default
  )
  let announcing = NotchController.hoverTarget(
    barVisible: true, presentation: .closed, notch: notch, isVirtual: true,
    appearance: .default
  )

  #expect(bare == notch)
  #expect(widened == NotchAppearance.default.closedRect(around: notch))
  #expect(announcing == NotchAppearance.default.closedRect(around: notch))
}

@Test func theNotchTargetReachesThePointerPressedAgainstTheTopEdge() {
  // `NSEvent.mouseLocation` reports a pointer on the screen's top row as exactly the
  // screen's maxY, which `CGRect.contains` counts as outside a rect ending there.
  let target = NotchController.notchTarget(
    barVisible: true, presentation: .closed, notch: notch, isVirtual: false,
    appearance: .default
  )

  #expect(target.contains(CGPoint(x: notch.midX, y: builtIn.maxY)))
  #expect(target == NotchAppearance.default.closedRect(around: notch).insetBy(dx: -4, dy: -4))
}

// MARK: - Panel target

@Test func thePanelTargetIsCentredOnTheCutoutAndHangsFromTheTop() {
  let panel = NotchController.panelTarget(
    notch: notch, screenFrame: builtIn, appearance: .default
  )

  #expect(panel.midX == notch.midX)
  #expect(panel.width == NotchAppearance.default.expandedWidth)
  #expect(panel.minY == builtIn.maxY - NotchAppearance.default.expandedHeight)
}

@Test func thePanelTargetIncludesThePointerPressedAgainstTheTopEdge() {
  // A press on the panel's top row, beside the notch, came back as outside the
  // panel and dismissed what was being pressed.
  let panel = NotchController.panelTarget(
    notch: notch, screenFrame: builtIn, appearance: .default
  )
  let besideTheNotch = notch.maxX + 120

  #expect(panel.contains(CGPoint(x: besideTheNotch, y: builtIn.maxY)))
  #expect(!panel.contains(CGPoint(x: besideTheNotch, y: panel.minY - 1)))
}
