import Foundation
import Testing

@testable import BoseSession

@Test func clockReportsAdvancedTime() {
  let clock = TestSessionClock()
  #expect(clock.now().elapsed == .zero)
  clock.advance(by: .seconds(3))
  #expect(clock.now().elapsed == .seconds(3))
}

@Test func sleepReturnsImmediatelyForPastDeadline() async throws {
  let clock = TestSessionClock()
  clock.advance(by: .seconds(10))
  // A deadline already behind the clock must not suspend.
  try await clock.sleep(until: BmapInstant(elapsed: .seconds(5)))
}

@Test func sleepResumesWhenTimeAdvancesPastDeadline() async throws {
  let clock = TestSessionClock()
  let woke = Task {
    try await clock.sleep(until: BmapInstant(elapsed: .milliseconds(200)))
    return true
  }
  // The sleeper must still be parked before time moves.
  #expect(await eventually { !woke.isCancelled && clock.now().elapsed == .zero })
  clock.advance(by: .milliseconds(200))
  #expect(try await woke.value)
}

@Test func sleepThrowsOnCancellation() async throws {
  let clock = TestSessionClock()
  let sleeper = Task {
    try await clock.sleep(until: BmapInstant(elapsed: .seconds(100)))
  }
  // Let the sleeper register, then cancel it: the clock never advances.
  try await Task.sleep(for: .milliseconds(20))
  sleeper.cancel()
  do {
    try await sleeper.value
    Issue.record("a cancelled sleep did not throw")
  } catch is CancellationError {
    // expected
  }
}
