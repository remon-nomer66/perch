import CoreGraphics
import Testing

@testable import NotchKit

/// Values shaped like a built-in display whose notch is 220pt wide and 38pt tall.
private let notch = CGRect(x: 790, y: 1131, width: 220, height: 38)

// MARK: - Real notch

@Test func theWidenedBarReachesEachSideByItsOwnExtension() {
  // The settings offer a left and a right reach separately. A bar centred on the
  // cutout splits their sum evenly instead, and then a strip of what is drawn on one
  // side never answers the pointer while an invisible strip on the other side does.
  var appearance = NotchAppearance.default
  appearance.leadingExtension = 76
  appearance.trailingExtension = 52
  let bar = appearance.barRect(
    around: notch, isVirtual: false, isBarExtended: true, presentation: .closed
  )

  #expect(bar.minX == notch.minX - 76)
  #expect(bar.maxX == notch.maxX + 52)
  #expect(bar.midX != notch.midX)
  #expect(bar == appearance.closedRect(around: notch))
}

@Test(arguments: [NotchPresenter.Presentation.closed, .popping])
func aRealNotchWithNoBarIsTheBareCutout(presentation: NotchPresenter.Presentation) {
  let bar = NotchAppearance.default.barRect(
    around: notch, isVirtual: false, isBarExtended: false, presentation: presentation
  )

  #expect(bar == notch)
}

// MARK: - Virtual notch

@Test func aVirtualNotchRestsAsTheSliverWhileClosedAndNotWidened() {
  let bar = NotchAppearance.default.barRect(
    around: notch, isVirtual: true, isBarExtended: false, presentation: .closed
  )

  #expect(bar == NotchAppearance.default.restingSliver(in: notch))
}

@Test func aVirtualNotchUnderThePointerIsTheWholeCutout() {
  // Once looked at, the sliver is drawn at the full cutout. Answering only at the
  // sliver would close it as soon as the pointer moved down into what is drawn.
  let bar = NotchAppearance.default.barRect(
    around: notch, isVirtual: true, isBarExtended: false, presentation: .popping
  )

  #expect(bar == notch)
}

@Test(arguments: [NotchPresenter.Presentation.closed, .popping])
func aWidenedVirtualNotchIsTheWholeBar(presentation: NotchPresenter.Presentation) {
  // Widened while closed is the arrival announcement: the bar is drawn in full, so
  // the sliver must not be all that answers a click on it.
  let bar = NotchAppearance.default.barRect(
    around: notch, isVirtual: true, isBarExtended: true, presentation: presentation
  )

  #expect(bar == NotchAppearance.default.closedRect(around: notch))
}
