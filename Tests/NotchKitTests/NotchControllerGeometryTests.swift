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
    barVisible: true, notch: notch, appearance: .default
  )

  #expect(target == NotchAppearance.default.closedRect(around: notch))
}

@Test func theHoverTargetShrinksToTheBareCutoutWhileTheBarIsHidden() {
  // With the bar hidden there is nothing beside the cutout to point at; the side
  // reaches of the invisible bar must not react to the pointer.
  let target = NotchController.hoverTarget(
    barVisible: false, notch: notch, appearance: .default
  )

  #expect(target == notch)
}
