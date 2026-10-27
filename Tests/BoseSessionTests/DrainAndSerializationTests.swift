import BoseCore
import Foundation
import Testing

@testable import BoseSession

/// The drain runs from the moment the session opens, so a STATUS that arrives before
/// any request is issued is delivered to `notifications` rather than dropped.
@Test func unsolicitedStatusBeforeAnySendIsNotLost() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())

  let received = Task { () -> BmapFrame? in
    for await frame in session.notifications { return frame }
    return nil
  }

  // No request is in flight, so this frame matches nothing and is unsolicited.
  mock.deliver(try makeStatus(.battery, [0x50, 0xff, 0xff, 0x00]))

  let frame = try #require(await received.value)
  #expect(frame.address == .battery)
  #expect(frame.op == .status)
  await session.close()
}

/// A frame that does not match the in-flight request is treated as unsolicited and
/// still reaches `notifications`, so nothing is lost while a request is outstanding.
@Test func frameNotMatchingInFlightGoesToNotifications() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )

  let received = Task { () -> BmapFrame? in
    for await frame in session.notifications { return frame }
    return nil
  }

  let get = try BmapNoiseCancellationReader.readRequest()
  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  // A battery STATUS arrives while a [1.5] request is in flight: not a match, so it is
  // an unsolicited notification.
  mock.deliver(try makeStatus(.battery, [0x50, 0xff, 0xff, 0x00]))
  let unsolicited = try #require(await received.value)
  #expect(unsolicited.address == .battery)

  // The request is still open and resolves on its own matching answer.
  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 0x05, 0x03]))
  let reply = try await task.value
  #expect(reply.address == .noiseCancellationRead)
  await session.close()
}

/// Requests are strictly serialised: while one is in flight the next is queued and does
/// not reach the wire until the first resolves. Answers are attributed to the request
/// in flight, in order.
@Test func requestsAreSerialisedFIFO() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let first = try BmapNoiseCancellationReader.readRequest()
  let second = try BmapProductInfo.firmwareRequest()

  let firstTask = Task { try await session.request(first) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  let secondTask = Task { try await session.request(second) }
  // Give the second request room to run; it must queue, never reach the wire yet.
  try await Task.sleep(for: .milliseconds(100))
  #expect(await mock.sends(at: .firmwareVersion) == 0, "a queued request reached the wire early")

  // Resolving the first hands the wire to the second.
  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 0x05, 0x03]))
  let firstReply = try await firstTask.value
  #expect(firstReply.address == .noiseCancellationRead)

  #expect(await eventually { await mock.sends(at: .firmwareVersion) == 1 })
  mock.deliver(try makeResult(.firmwareVersion, Array("1.0.0".utf8)))
  let secondReply = try await secondTask.value
  #expect(secondReply.address == .firmwareVersion)
  await session.close()
}

/// Closing the session interrupts a waiting request rather than leaving it hung.
@Test func closingSessionFailsInFlightRequest() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  await session.close()
  do {
    _ = try await task.value
    Issue.record("a request survived the session closing")
  } catch let error as BoseRequestError {
    #expect(error == .sessionClosed)
  }
}
