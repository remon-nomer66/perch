import BoseCore
import Foundation
import Testing

@testable import BoseSession

@Test func drainAccumulatesStatusesUntilIdle() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock,
    settings: instantSettings(drainIdle: .milliseconds(500), drainOverall: .seconds(30))
  )
  // Synthetic GetAll: one GET, a run of STATUS answers back.
  let getAll = try BmapFrame(fblock: 2, function: 2, op: .get)

  let task = Task {
    try await session.requestMany(getAll, matching: { $0.op == .status })
  }
  #expect(await eventually { await mock.sends(at: .battery) == 1 })

  // Three STATUS frames in one chunk, so the whole run arrives in a single append.
  mock.deliver([
    try makeStatus(.battery, [50, 0xff, 0xff, 0x00]),
    try makeStatus(.battery, [80, 0xff, 0xff, 0x01]),
    try makeStatus(.battery, [90, 0xff, 0xff, 0x02]),
  ])

  // Let the drain consume all three and arm its idle wait, then advance past the idle
  // window so the drain ends on idle rather than on the overall deadline.
  try await Task.sleep(for: .milliseconds(50))
  #expect(await eventually { await session.isAwaitingFrame })
  clock.advance(by: .milliseconds(500))

  let frames = try await task.value
  #expect(frames.count == 3)
  await session.close()
}

@Test func drainStopsAtOverallDeadline() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock,
    // Idle is long enough that it cannot be what ends the drain; the overall deadline is.
    settings: instantSettings(drainIdle: .seconds(30), drainOverall: .milliseconds(500))
  )
  let getAll = try BmapFrame(fblock: 2, function: 2, op: .get)

  let task = Task {
    try await session.requestMany(getAll, matching: { $0.op == .status })
  }
  #expect(await eventually { await mock.sends(at: .battery) == 1 })

  mock.deliver([
    try makeStatus(.battery, [50, 0xff, 0xff, 0x00]),
    try makeStatus(.battery, [80, 0xff, 0xff, 0x01]),
  ])

  try await Task.sleep(for: .milliseconds(50))
  #expect(await eventually { await session.isAwaitingFrame })
  // Idle would keep waiting 30s; the overall deadline cuts the drain off at 500ms.
  clock.advance(by: .milliseconds(500))

  let frames = try await task.value
  #expect(frames.count == 2)
  await session.close()
}

@Test func drainAbortsOnErrorEvenWithAStatusOnlyMatcher() async throws {
  // Regression: a narrow matcher (`{ $0.op == .status }`) used to route the device's
  // ERROR to the notification stream, so the drain never saw it and reported the wrong
  // outcome. The matcher is now widened to always deliver an ERROR at the request's
  // address, so the drain aborts with the typed device error whatever the predicate.
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock,
    settings: instantSettings(drainIdle: .milliseconds(500), drainOverall: .seconds(30))
  )
  let getAll = try BmapFrame(fblock: 2, function: 2, op: .get)

  let task = Task {
    try await session.requestMany(getAll, matching: { $0.op == .status })
  }
  #expect(await eventually { await mock.sends(at: .battery) == 1 })

  // One good STATUS, then an ERROR at the same address mid-stream.
  mock.deliver([
    try makeStatus(.battery, [50, 0xff, 0xff, 0x00]),
    try makeError(.battery, code: BmapErrorCode.runtime.rawValue),
  ])

  do {
    _ = try await task.value
    Issue.record("an ERROR during drain was not surfaced")
  } catch let error as BoseRequestError {
    #expect(error == .device(.runtime))
  }
  await session.close()
}

@Test func drainReportsNoResponseWhenNothingArrives() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock,
    settings: instantSettings(responseTimeout: .seconds(5), drainOverall: .seconds(30))
  )
  let getAll = try BmapFrame(fblock: 2, function: 2, op: .get)

  let task = Task {
    try await session.requestMany(getAll, matching: { $0.op == .status })
  }
  #expect(await eventually { await mock.sends(at: .battery) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  clock.advance(by: .seconds(5))
  do {
    _ = try await task.value
    Issue.record("an empty drain did not report noResponse")
  } catch let error as BoseRequestError {
    #expect(error == .noResponse)
  }
  await session.close()
}
