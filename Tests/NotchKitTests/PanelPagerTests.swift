import Testing

@testable import NotchKit

private func pager(_ pages: Int = 5) -> PanelPager {
  PanelPager(pageCount: pages, threshold: 30)
}

@Test func aFlickMovesExactlyOnePage() {
  var subject = pager()
  subject.handle(.init(delta: -10, phase: .began))
  subject.handle(.init(delta: -15, phase: .changed))
  let crossed = subject.handle(.init(delta: -20, phase: .changed))

  #expect(crossed == .moved(to: 1))

  // The rest of the same gesture must not keep advancing.
  subject.handle(.init(delta: -40, phase: .changed))
  subject.handle(.init(delta: -60, phase: .changed))
  #expect(subject.index == 1, "one gesture moved more than one page")
}

@Test func momentumAfterAFlickIsIgnored() {
  var subject = pager()
  subject.handle(.init(delta: -35, phase: .began))
  subject.handle(.init(delta: 0, phase: .ended))
  #expect(subject.index == 1)

  // A trackpad keeps sending events after the fingers lift; acting on them skips
  // several pages from a single flick.
  for delta in [-30.0, -25.0, -18.0, -12.0, -6.0] {
    subject.handle(.init(delta: delta, phase: .changed, isMomentum: true))
  }
  #expect(subject.index == 1, "momentum advanced the pager")
}

@Test func aNewGestureCanMoveAgain() {
  var subject = pager()
  subject.handle(.init(delta: -35, phase: .began))
  subject.handle(.init(delta: 0, phase: .ended))
  subject.handle(.init(delta: -35, phase: .began))

  #expect(subject.index == 2)
}

@Test func aMouseWheelWithoutPhasesStillPages() {
  // A mouse reports no phase, so there is no gesture to latch. Each threshold
  // crossing is a separate intent.
  var subject = pager()
  subject.handle(.init(delta: -35))
  #expect(subject.index == 1)
  subject.handle(.init(delta: -35))
  #expect(subject.index == 2)
}

@Test func scrollingBackMovesTowardsTheFirstPage() {
  var subject = pager()
  subject.select(3)
  subject.handle(.init(delta: 35, phase: .began))
  #expect(subject.index == 2)
}

@Test func smallMovementsAccumulateRatherThanBeingLost() {
  var subject = pager()
  for _ in 0..<5 {
    subject.handle(.init(delta: -7, phase: .changed))
  }
  #expect(subject.index == 1, "slow scrolling never reached the threshold")
}

@Test func theEndsResistRatherThanWrapping() {
  var subject = pager()
  #expect(subject.handle(.init(delta: 35, phase: .began)) == .resisted)
  #expect(subject.index == 0)

  subject.select(4)
  #expect(subject.handle(.init(delta: -35, phase: .began)) == .resisted)
  #expect(subject.index == 4)
}

@Test func removingPagesKeepsTheIndexValid() {
  var subject = pager()
  subject.select(4)
  subject.setPageCount(2)
  #expect(subject.index == 1)
}

@Test func aSinglePageNeverMoves() {
  var subject = PanelPager(pageCount: 1)
  #expect(subject.handle(.init(delta: -100, phase: .began)) == .resisted)
  #expect(subject.index == 0)
}
