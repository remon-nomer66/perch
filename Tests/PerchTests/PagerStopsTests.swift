import Testing

@testable import Perch

// The pager's stop count must always agree with what NotchPanelView.displayedPages
// renders: every sheet while the device is readable, else the common sheets plus the
// one status sheet. A pager left on the full count while the view collapsed would
// swipe through stops that are not on screen.

@MainActor
@Test("A readable device offers every sheet")
func readableOffersAll() {
  #expect(AppModel.pagerStops(for: .ready) == PanelPages.count)
  #expect(AppModel.pagerStops(for: .unverified(caveat: "")) == PanelPages.count)
}

@MainActor
@Test("Anything else collapses to the common sheets plus the status sheet")
func collapsedStates() {
  let collapsed = PanelPages.commonPageIDs.count + 1
  #expect(AppModel.pagerStops(for: .noDevice) == collapsed)
  #expect(AppModel.pagerStops(for: .connecting) == collapsed)
  #expect(AppModel.pagerStops(for: .reading) == collapsed)
  #expect(AppModel.pagerStops(for: .takenByAnotherDevice) == collapsed)
  #expect(AppModel.pagerStops(for: .unreachable) == collapsed)
}
