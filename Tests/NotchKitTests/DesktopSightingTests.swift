import CoreGraphics
import Testing

@testable import NotchKit

private let notchScreen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
private let otherScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let withDesktop = FullScreenReading(reason: .menuBarOverTheDesktop, showsDesktop: true)
private let withoutDesktop = FullScreenReading(reason: .desktopNeverSeen, showsDesktop: false)

@Test func noDesktopIsSeenBeforeTheFirstReading() {
  #expect(!DesktopSighting().hasSeenDesktop(on: notchScreen))
}

@Test func readingsWithoutTheDesktopNeverMarkItSeen() {
  let subject = DesktopSighting()
    .noting(withoutDesktop, on: notchScreen)
    .noting(withoutDesktop, on: notchScreen)

  #expect(!subject.hasSeenDesktop(on: notchScreen))
}

@Test func aSeenDesktopStaysSeenOnItsScreen() {
  // Entering full screen is exactly when the desktop goes missing; that must not erase
  // the sighting that gives its absence meaning.
  let subject = DesktopSighting()
    .noting(withDesktop, on: notchScreen)
    .noting(withoutDesktop, on: notchScreen)

  #expect(subject.hasSeenDesktop(on: notchScreen))
}

@Test func anotherScreenDiscardsTheSighting() {
  let seen = DesktopSighting().noting(withDesktop, on: notchScreen)
  let moved = seen.noting(withoutDesktop, on: otherScreen)

  #expect(!seen.hasSeenDesktop(on: otherScreen))
  #expect(!moved.hasSeenDesktop(on: otherScreen))
  // Coming back does not restore it: the record went with the change.
  #expect(!moved.noting(withoutDesktop, on: notchScreen).hasSeenDesktop(on: notchScreen))
}
