import CoreGraphics
import Testing

@testable import NotchKit

/// Values shaped like a built-in display with a 39pt menu bar and a 220pt notch.
private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
private let notch = CGRect(x: 790, y: 1131, width: 220, height: 38)
private let catcherNumber = 4242

private var barTarget: CGRect {
  NotchController.notchTarget(
    barVisible: true, presentation: .closed, notch: notch, isVirtual: false,
    appearance: .default
  )
}

private func press(
  _ route: PointerClick.Route, count: Int = 1, window: Int? = nil
) -> PointerClick {
  PointerClick(
    location: CGPoint(x: notch.midX, y: notch.midY),
    route: route,
    clickCount: count,
    windowNumber: window
  )
}

// MARK: - Catcher frame

@Test(arguments: [NotchPresenter.Presentation.closed, .popping])
func theCatcherCoversTheNotchTargetOnScreen(presentation: NotchPresenter.Presentation) {
  let frame = NotchController.catcherFrame(
    presentation: presentation, notchTarget: barTarget, screenFrame: screen
  )

  #expect(frame == barTarget.intersection(screen))
}

@Test func theCatcherStepsAsideWhileThePanelIsOpen() {
  // Open, the strip itself takes the presses; a catcher left over the notch would
  // stand between the pointer and the panel's own header.
  let frame = NotchController.catcherFrame(
    presentation: .opened, notchTarget: barTarget, screenFrame: screen
  )

  #expect(frame == nil)
}

@Test func theCatcherLeavesTheRestOfTheMenuBarAlone() throws {
  // The whole point of a separate catcher: the strip spans the screen, the catcher
  // only the bar, so a press on any other menu bar item still reaches it.
  let frame = try #require(
    NotchController.catcherFrame(
      presentation: .closed, notchTarget: barTarget, screenFrame: screen
    )
  )
  let menuBarY = screen.maxY - 20
  let strip = NotchController.stripRect(screenFrame: screen, expandedHeight: 200)

  #expect(frame.width < strip.width / 4)
  #expect(!frame.contains(CGPoint(x: 100, y: menuBarY)))
  #expect(!frame.contains(CGPoint(x: barTarget.maxX + 1, y: menuBarY)))
  #expect(!frame.contains(CGPoint(x: barTarget.minX - 1, y: menuBarY)))
  #expect(!frame.contains(CGPoint(x: notch.midX, y: barTarget.minY - 1)))
}

@Test func theCatcherNeverReachesAScreenArrangedAbove() throws {
  // The target's slack runs past the top edge. As a window frame that would swallow
  // presses along the bottom of a display stacked above the notch screen.
  let frame = try #require(
    NotchController.catcherFrame(
      presentation: .closed, notchTarget: barTarget, screenFrame: screen
    )
  )

  #expect(frame.maxY == screen.maxY)
}

@Test func aTargetOffTheScreenHasNoCatcher() {
  let frame = NotchController.catcherFrame(
    presentation: .closed,
    notchTarget: CGRect(x: 0, y: 5000, width: 100, height: 40),
    screenFrame: screen
  )

  #expect(frame == nil)
}

// MARK: - Presses

@Test(arguments: [NotchPresenter.Presentation.closed, .popping])
func aPressOnTheCatcherIsOnTheNotchWhateverTheGeometrySays(
  presentation: NotchPresenter.Presentation
) {
  // The catcher swallowed it: the window server already found the pointer on the bar.
  // Doing nothing with a press nobody else got is exactly the "click does nothing"
  // the catcher exists to end.
  let event = NotchController.presenterEvent(
    for: press(.local, window: catcherNumber),
    presentation: presentation,
    catcherWindowNumber: catcherNumber,
    isOverNotch: false,
    isInsidePanel: false
  )

  #expect(event == .clicked(isOverNotch: true, isInsidePanel: false))
}

@Test func aStalePressOnTheCatcherWhileOpenFollowsTheGeometry() {
  // Open, the catcher stands aside; a press still routed to it was queued before it
  // did, and must not be taken as a click on the notch that shuts the panel.
  let event = NotchController.presenterEvent(
    for: press(.local, window: catcherNumber),
    presentation: .opened,
    catcherWindowNumber: catcherNumber,
    isOverNotch: false,
    isInsidePanel: true
  )

  #expect(event == .clicked(isOverNotch: false, isInsidePanel: true))
}

@Test func aPressElsewhereKeepsTheGeometrysAnswer() {
  let onThePanel = NotchController.presenterEvent(
    for: press(.local, window: catcherNumber + 1),
    presentation: .opened,
    catcherWindowNumber: catcherNumber,
    isOverNotch: false,
    isInsidePanel: true
  )
  let onTheMenuBar = NotchController.presenterEvent(
    for: press(.global),
    presentation: .closed,
    catcherWindowNumber: catcherNumber,
    isOverNotch: false,
    isInsidePanel: false
  )

  #expect(onThePanel == .clicked(isOverNotch: false, isInsidePanel: true))
  #expect(onTheMenuBar == .clicked(isOverNotch: false, isInsidePanel: false))
}

@Test func aGlobalPressNeverCountsAsTheCatcher() {
  // Another process's window number says nothing about ours.
  let event = NotchController.presenterEvent(
    for: press(.global, window: catcherNumber),
    presentation: .closed,
    catcherWindowNumber: catcherNumber,
    isOverNotch: false,
    isInsidePanel: false
  )

  #expect(event == .clicked(isOverNotch: false, isInsidePanel: false))
}

@Test func aPressWithNoWindowIsNotTheCatcher() {
  // Two unknowns are not a match: with no catcher up, a press aimed at no window
  // must not open the panel.
  let event = NotchController.presenterEvent(
    for: press(.local, window: nil),
    presentation: .closed,
    catcherWindowNumber: nil,
    isOverNotch: false,
    isInsidePanel: false
  )

  #expect(event == .clicked(isOverNotch: false, isInsidePanel: false))
}

// MARK: - Double clicks

/// One pointer session: presses fed to a presenter through the filter, the way the
/// controller feeds them.
private struct Session {
  var presenter = NotchPresenter()
  var filter = DoubleClickFilter()

  mutating func press(count: Int, overNotch: Bool, insidePanel: Bool) {
    let click = PointerClick(
      location: .zero, route: .local, clickCount: count, windowNumber: nil
    )
    let event = NotchController.presenterEvent(
      for: click,
      presentation: presenter.presentation,
      catcherWindowNumber: catcherNumber,
      isOverNotch: overNotch,
      isInsidePanel: insidePanel
    )
    filter.pass(event, of: click, to: &presenter)
  }
}

@Test func aDoubleClickOnTheClosedBarLeavesThePanelOpen() {
  // The first press opens. The second lands on the panel now under the pointer and,
  // read as a click on the notch, would shut it again at once.
  var session = Session()
  session.press(count: 1, overNotch: true, insidePanel: true)
  session.press(count: 2, overNotch: true, insidePanel: true)

  #expect(session.presenter.presentation == .opened)
}

@Test func aTripleClickIsStillOneClick() {
  var session = Session()
  for count in 1...3 {
    session.press(count: count, overNotch: true, insidePanel: true)
  }

  #expect(session.presenter.presentation == .opened)
}

@Test func aDoubleClickOnTheNotchWhileOpenLeavesItClosed() {
  var session = Session()
  session.press(count: 1, overNotch: true, insidePanel: true)
  session.press(count: 1, overNotch: true, insidePanel: true)
  session.press(count: 2, overNotch: true, insidePanel: true)

  #expect(session.presenter.presentation == .closed)
}

@Test func aQuickPressAfterOneThatDidNothingStillActs() {
  // A press on a control in the panel changes nothing; the notch pressed straight
  // after it can still count as the second press of a double click, and swallowing it
  // would leave a dead click on the notch.
  var session = Session()
  session.press(count: 1, overNotch: true, insidePanel: true)
  session.press(count: 1, overNotch: false, insidePanel: true)
  session.press(count: 2, overNotch: true, insidePanel: true)

  #expect(session.presenter.presentation == .closed)
}

@Test func theNextSeparateClickOnTheNotchStillCloses() {
  var session = Session()
  session.press(count: 1, overNotch: true, insidePanel: true)
  session.press(count: 1, overNotch: true, insidePanel: true)

  #expect(session.presenter.presentation == .closed)
}

@Test func aHeldBackPressIsReportedAsSuch() {
  var presenter = NotchPresenter()
  var filter = DoubleClickFilter()
  let first = PointerClick(location: .zero, route: .local, clickCount: 1, windowNumber: nil)
  let second = PointerClick(location: .zero, route: .local, clickCount: 2, windowNumber: nil)
  let onTheNotch = NotchPresenter.Event.clicked(isOverNotch: true, isInsidePanel: true)

  #expect(filter.pass(onTheNotch, of: first, to: &presenter))
  #expect(!filter.pass(onTheNotch, of: second, to: &presenter))
}
