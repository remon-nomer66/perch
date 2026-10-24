import Testing

@testable import NotchKit

private func policy(
  _ route: PointerClick.Route,
  onCatcher: Bool = false,
  overNotch: Bool = false,
  insidePanel: Bool = false,
  presentation: NotchPresenter.Presentation = .closed
) -> ClickLogPolicy {
  ClickLogPolicy(
    route: route,
    landedOnCatcher: onCatcher,
    isOverNotch: overNotch,
    isInsidePanel: insidePanel,
    presentation: presentation
  )
}

// MARK: - What is kept for later

@Test func aPressTheCatcherTookIsKeptForLater() {
  // Debug messages are not persisted. Whether the catcher takes presses at all is the
  // first question when a click on the notch does nothing, so it must survive to a
  // `log show` the user runs afterwards.
  let kept = policy(.local, onCatcher: true, overNotch: true)

  #expect(kept.isNotable)
  #expect(kept.recordsLocation)
}

@Test func aPressOverTheNotchThatArrivedGloballyIsKeptForLater() {
  // A press on the bar should have landed on the catcher; one that reached another
  // process instead is the other half of the same question.
  let kept = policy(.global, overNotch: true)

  #expect(kept.isNotable)
  #expect(kept.recordsLocation)
}

@Test func everyOtherPressStaysAtDebug() {
  #expect(!policy(.local, overNotch: true, presentation: .opened).isNotable)
  #expect(!policy(.local, insidePanel: true, presentation: .opened).isNotable)
  #expect(!policy(.global).isNotable)
}

// MARK: - Where it landed

@Test func aPressOnWhatTheNotchDrawsRecordsWhereItLanded() {
  #expect(policy(.local, overNotch: true, presentation: .opened).recordsLocation)
  #expect(policy(.local, insidePanel: true, presentation: .opened).recordsLocation)
}

@Test func aPressAnywhereElseRecordsNoLocation() {
  // The global monitor sees every press on the screen. Where the user clicks in other
  // apps is none of this log's business.
  #expect(!policy(.global).recordsLocation)
  #expect(!policy(.global, presentation: .opened).recordsLocation)
}

@Test func thePanelsRectangleCountsOnlyWhileThePanelIsOpen() {
  // Closed, the panel's rectangle is just someone else's window below the menu bar.
  #expect(!policy(.global, insidePanel: true, presentation: .closed).recordsLocation)
  #expect(!policy(.global, insidePanel: true, presentation: .popping).recordsLocation)
}
