import Foundation
import Testing

@testable import NotchKit

private let taken = FullScreenReading(reason: .menuBarWithoutDesktop)
private let notTaken = FullScreenReading(reason: .menuBarOverTheDesktop)
private let settle = FullScreenHysteresis.settleTime

/// Applies the readings in order, each at the time paired with it.
private func after(_ readings: [(FullScreenReading, TimeInterval)]) -> FullScreenHysteresis {
  readings.reduce(FullScreenHysteresis()) { $0.applying($1.0, at: $1.1) }
}

@Test func oneTakenReadingIsNotEnough() {
  // A single reading may have been taken mid-slide, while a space was still moving in.
  let subject = after([(taken, 0)])

  #expect(!subject.isFullScreen)
  #expect(subject.isAwaitingConfirmation)
}

@Test func aSecondTakenReadingOnceSettledTakesTheScreen() {
  let subject = after([(taken, 0), (taken, settle)])

  #expect(subject.isFullScreen)
  #expect(!subject.isAwaitingConfirmation)
}

@Test func twoReadingsAtOnceAreNotTwoLooks() {
  // Notifications arriving together read the same moment of the same slide twice.
  let subject = after([(taken, 0), (taken, 0.003)])

  #expect(!subject.isFullScreen)
  #expect(subject.isAwaitingConfirmation)
}

@Test func theSettleTimeRunsFromTheFirstReadingOfTheRun() {
  // Readings in between neither restart the wait nor end it early.
  let subject = after([(taken, 0), (taken, settle / 2), (taken, settle)])

  #expect(subject.isFullScreen)
}

@Test func anInterruptedRunStartsOver() {
  // Readings flipping back and forth through a transition never add up to a takeover.
  let subject = after([(taken, 0), (notTaken, settle / 2), (taken, settle)])

  #expect(!subject.isFullScreen)
  #expect(subject.isAwaitingConfirmation)
}

@Test func oneNotTakenReadingReleasesTheScreenAtOnce() {
  // Coming back is never held: a notch hidden by mistake cannot be reached at all.
  let subject = after([(taken, 0), (taken, settle), (notTaken, settle + 0.001)])

  #expect(!subject.isFullScreen)
  #expect(!subject.isAwaitingConfirmation)
}

@Test func furtherTakenReadingsKeepTheScreenTaken() {
  let subject = after([(taken, 0), (taken, settle), (taken, settle * 2), (taken, settle * 3)])

  #expect(subject.isFullScreen)
}

@Test func takenReadingsCountWhateverTheirReason() {
  // A game hiding the bar and a full-screen space look different to the rule, but a
  // space sliding in can show one and then the other; both say "taken".
  let subject = after([
    (FullScreenReading(reason: .menuBarGone), 0),
    (FullScreenReading(reason: .menuBarWithoutDesktop), settle),
  ])

  #expect(subject.isFullScreen)
}

@Test func nothingReadIsNeverTaken() {
  let subject = after([
    (FullScreenReading(reason: .nothingToRead), 0),
    (FullScreenReading(reason: .nothingToRead), settle),
  ])

  #expect(!subject.isFullScreen)
  #expect(!subject.isAwaitingConfirmation)
}
