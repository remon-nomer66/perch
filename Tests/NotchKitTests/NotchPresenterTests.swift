import Testing

@testable import NotchKit

private func presenter() -> NotchPresenter { NotchPresenter() }

@Test func pointingAtTheNotchHintsWithoutOpening() {
  var subject = presenter()
  subject.handle(.pointerMoved(isOverNotch: true))
  #expect(subject.presentation == .popping)

  subject.handle(.pointerMoved(isOverNotch: false))
  #expect(subject.presentation == .closed)
}

@Test func clickingTheNotchOpensIt() {
  var subject = presenter()
  subject.handle(.pointerMoved(isOverNotch: true))
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))
  #expect(subject.presentation == .opened)
}

@Test func anOpenPanelSurvivesThePointerLeaving() {
  // This is the whole reason the pointer never closes the panel: every control in it
  // is somewhere the pointer has to travel to.
  var subject = presenter()
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))

  subject.handle(.pointerMoved(isOverNotch: false))
  subject.handle(.pointerMoved(isOverNotch: false))
  #expect(subject.presentation == .opened, "moving the pointer closed the panel")
}

@Test func clickingOutsideCloses() {
  var subject = presenter()
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))
  subject.handle(.clicked(isOverNotch: false, isInsidePanel: false))
  #expect(subject.presentation == .closed)
}

@Test func clickingInsideThePanelDoesNotClose() {
  var subject = presenter()
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))

  // Pressing a control counts as a click, and must not dismiss what it is acting on.
  subject.handle(.clicked(isOverNotch: false, isInsidePanel: true))
  #expect(subject.presentation == .opened)
}

@Test func clickingTheNotchAgainCloses() {
  var subject = presenter()
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))
  #expect(subject.presentation == .closed)
}

@Test func pointingAtTheNotchWhileOpenChangesNothing() {
  var subject = presenter()
  subject.handle(.clicked(isOverNotch: true, isInsidePanel: true))
  subject.handle(.pointerMoved(isOverNotch: true))
  #expect(subject.presentation == .opened)
}

@Test func dismissClosesFromAnyState() {
  for setup: [NotchPresenter.Event] in [
    [],
    [.pointerMoved(isOverNotch: true)],
    [.clicked(isOverNotch: true, isInsidePanel: true)],
  ] {
    var subject = presenter()
    setup.forEach { subject.handle($0) }
    subject.handle(.dismiss)
    #expect(subject.presentation == .closed)
  }
}
