import Testing
import TandemSession

@testable import Perch

// MARK: - Phase mapping

@Test("Each session phase maps to the status the panel words are written for")
func phaseMapsToStatus() {
  #expect(DeviceSummary.status(for: .released, reason: nil) == .noDevice)
  #expect(
    DeviceSummary.status(for: .sleeping(resume: .reconnect), reason: nil) == .noDevice
  )
  #expect(DeviceSummary.status(for: .connecting, reason: nil) == .connecting)
  #expect(DeviceSummary.status(for: .verifying, reason: nil) == .reading)
  #expect(DeviceSummary.status(for: .recovering, reason: nil) == .reading)
  #expect(DeviceSummary.status(for: .contended, reason: nil) == .takenByAnotherDevice)
  #expect(DeviceSummary.status(for: .retryWaiting, reason: nil) == .unreachable)
  #expect(DeviceSummary.status(for: .retryExhausted, reason: nil) == .unreachable)
  #expect(DeviceSummary.status(for: .ready, reason: nil) == .ready)
}

@Test("Unverified carries a caveat; suspension resumes into the phase it left")
func unverifiedAndSuspendedStatuses() {
  if case .unverified = DeviceSummary.status(for: .unverified, reason: nil) {
  } else {
    Issue.record("unverified phase should map to the unverified status")
  }
  #expect(DeviceSummary.status(for: .suspended(resume: .ready), reason: nil) == .ready)
  if case .unverified = DeviceSummary.status(for: .suspended(resume: .unverified), reason: nil) {
  } else {
    Issue.record("a suspension out of unverified should stay unverified")
  }
}

@Test("Controllable means ready or unverified, nothing else")
func controllableStatuses() {
  var summary = DeviceSummary()
  summary.status = .ready
  #expect(summary.isControllable)
  summary.status = .unverified(caveat: "caveat")
  #expect(summary.isControllable)
  for status: DeviceSummary.Status in [
    .noDevice, .connecting, .reading, .takenByAnotherDevice, .unreachable,
  ] {
    summary.status = status
    #expect(!summary.isControllable)
  }
}

// MARK: - Read-only caveat

@Test("A controllable session that refuses writes says read-only over anything else")
func readOnlyCaveatWinsWhileControllable() {
  var summary = DeviceSummary()
  summary.status = .unverified(caveat: "unverified caveat")
  summary.acceptsWrites = false
  let caveat = summary.caveat
  #expect(caveat != nil)
  #expect(caveat != "unverified caveat")

  // Writes admitted again: the unverified caveat returns.
  summary.acceptsWrites = true
  #expect(summary.caveat == "unverified caveat")
}

@Test("Refused writes without a controllable session show no caveat")
func readOnlyCaveatNeedsControllableSession() {
  var summary = DeviceSummary()
  summary.status = .connecting
  summary.acceptsWrites = false
  #expect(summary.caveat == nil)
}

// MARK: - Unreachable debounce

@Test("Unreachable reads as connecting until it has held for the hold-off")
func unreachableIsHeldBack() {
  var debounce = UnreachableDebounce(holdOff: .seconds(3))
  let start = ContinuousClock.now
  #expect(debounce.present(.unreachable, now: start) == .connecting)
  #expect(debounce.present(.unreachable, now: start.advanced(by: .seconds(1))) == .connecting)
  #expect(debounce.present(.unreachable, now: start.advanced(by: .seconds(3))) == .unreachable)
  #expect(debounce.present(.unreachable, now: start.advanced(by: .seconds(9))) == .unreachable)
}

@Test("Any other status passes through and resets the clock")
func otherStatusesResetTheDebounce() {
  var debounce = UnreachableDebounce(holdOff: .seconds(3))
  let start = ContinuousClock.now
  #expect(debounce.present(.unreachable, now: start) == .connecting)
  // The device came back: the status passes through untouched.
  #expect(debounce.present(.ready, now: start.advanced(by: .seconds(1))) == .ready)
  // A later loss starts a fresh hold-off rather than inheriting the first one.
  let laterLoss = start.advanced(by: .seconds(10))
  #expect(debounce.present(.unreachable, now: laterLoss) == .connecting)
  #expect(
    debounce.present(.unreachable, now: laterLoss.advanced(by: .seconds(2))) == .connecting
  )
  #expect(
    debounce.present(.unreachable, now: laterLoss.advanced(by: .seconds(3))) == .unreachable
  )
}
