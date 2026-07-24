import BoseCore
import Foundation
import Testing

@testable import BoseSession

/// QC35 stays silent until it is pinged, and can drop the odd ping, so connect resends
/// the [0.1] init until the device answers. The mock ignores the first init and answers
/// the second.
@Test func qc35ConnectResendsInitUntilAnswered() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    config: .qc35,
    clock: clock,
    settings: instantSettings(maxConnectAttempts: 5, connectResponseTimeout: .seconds(2))
  )

  let task = Task { try await session.connect() }

  // First init goes out and is ignored.
  #expect(await eventually { await mock.sends(at: .initialize) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  // Advancing past the connect timeout fires the resend on the injected clock.
  clock.advance(by: .seconds(2))
  #expect(await eventually { await mock.sends(at: .initialize) == 2 })

  // The device now answers the init (a CONNECT ack at [0.1]); connect succeeds.
  mock.deliver(try makeStatus(.initialize, [0x03, 0x05]))
  try await task.value
  await session.close()
}

@Test func qc35ConnectGivesUpAfterCap() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    config: .qc35,
    clock: clock,
    settings: instantSettings(maxConnectAttempts: 3, connectResponseTimeout: .seconds(2))
  )

  let task = Task { try await session.connect() }

  // Never answer; each timeout triggers the next resend until the cap is hit.
  for attempt in 1...3 {
    #expect(await eventually { await mock.sends(at: .initialize) == attempt })
    #expect(await eventually { await session.isAwaitingFrame })
    clock.advance(by: .seconds(2))
  }

  do {
    try await task.value
    Issue.record("connect did not give up after the cap")
  } catch let error as BoseSessionError {
    #expect(error == .connectFailed(attempts: 3))
  }
  #expect(await mock.sends(at: .initialize) == 3)
  await session.close()
}

/// Ultra 2 needs no connect-time init: GETs work immediately, so connect sends nothing
/// and returns at once.
@Test func ultraConnectSendsNoInit() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(config: .qcUltra2, clock: clock, settings: instantSettings())

  try await session.connect()
  #expect(await mock.sendCount() == 0)
  await session.close()
}

/// A cancel while connect is waiting for the init answer reports `.cancelled`, not a
/// spurious "resent to the cap" — the device never went silent through every retry.
@Test func qc35ConnectReportsCancellation() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    config: .qc35, clock: clock,
    settings: instantSettings(maxConnectAttempts: 5, connectResponseTimeout: .seconds(2))
  )

  let task = Task { try await session.connect() }
  #expect(await eventually { await mock.sends(at: .initialize) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  task.cancel()
  do {
    try await task.value
    Issue.record("cancelled connect did not throw")
  } catch let error as BoseSessionError {
    #expect(error == .cancelled)
  }
  await session.close()
}

/// A transport failure during connect surfaces the underlying cause, not a fake attempt
/// count.
@Test func connectReportsChannelFailure() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    config: .qc35, clock: clock, settings: instantSettings()
  )
  await mock.failSends(with: .notConnected)

  do {
    try await session.connect()
    Issue.record("connect over a failing channel did not throw")
  } catch let error as BoseSessionError {
    #expect(error == .channel(.notConnected))
  }
  await session.close()
}
