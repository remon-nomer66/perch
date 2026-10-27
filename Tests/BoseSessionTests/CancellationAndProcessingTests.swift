import BoseCore
import Foundation
import Testing

@testable import BoseSession

@Test func cancellingAnInFlightRequestInterruptsTheWaiter() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  task.cancel()
  do {
    _ = try await task.value
    Issue.record("a cancelled request still resolved")
  } catch let error as BoseRequestError {
    #expect(error == .cancelled)
  }
  await session.close()
}

@Test func cancellingFreesTheWireForTheNextRequest() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let first = try BmapNoiseCancellationReader.readRequest()
  let second = try BmapProductInfo.firmwareRequest()

  let firstTask = Task { try await session.request(first) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  firstTask.cancel()
  _ = try? await firstTask.value

  // With the wire freed, a fresh request proceeds and resolves normally.
  let secondTask = Task { try await session.request(second) }
  #expect(await eventually { await mock.sends(at: .firmwareVersion) == 1 })
  mock.deliver(try makeResult(.firmwareVersion, Array("1.0.0".utf8)))
  let reply = try await secondTask.value
  #expect(reply.op == .result)
  await session.close()
}

@Test func cancellingWhileQueuedNeverSends() async throws {
  // A request cancelled while it is still waiting for the wire must not send once its
  // turn arrives: that would spend a device round trip on a result nobody awaits, whose
  // late answer could be mis-attributed to the next request at the same address.
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let holder = try BmapNoiseCancellationReader.readRequest()
  let queued = try BmapProductInfo.firmwareRequest()

  // First request takes the wire and parks awaiting its answer.
  let holderTask = Task { try await session.request(holder) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  // Second request queues behind it, then is cancelled while still queued. A queued
  // request only resolves once the wire is handed to it (matching the Sony session), so
  // it is not awaited until the holder is released below.
  let queuedTask = Task { try await session.request(queued) }
  #expect(await eventually { await session.queuedRequestCount == 1 })
  queuedTask.cancel()

  // Release the holder; the wire passes to the cancelled request, which throws before
  // sending. It must never have hit the wire.
  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 0x00, 0x03]))
  _ = try await holderTask.value
  do {
    _ = try await queuedTask.value
    Issue.record("a queued-then-cancelled request still resolved")
  } catch let error as BoseRequestError {
    #expect(error == .cancelled)
  }
  #expect(await mock.sends(at: .firmwareVersion) == 0)
  await session.close()
}

@Test func processingIsNotTerminalAndResultContinues() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(60))
  )
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  // PROCESSING then RESULT in one chunk: the request must skip the PROCESSING and
  // resolve on the RESULT that follows.
  mock.deliver([
    try makeProcessing(.noiseCancellationRead),
    try makeResult(.noiseCancellationRead, [0x0b, 0x07, 0x03]),
  ])

  let reply = try await task.value
  #expect(reply.op == .result)
  #expect(try BmapNoiseCancellationReader.parse(reply).currentStep == 7)
  await session.close()
}
