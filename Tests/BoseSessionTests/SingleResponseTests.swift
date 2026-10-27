import BoseCore
import Foundation
import Testing

@testable import BoseSession

@Test func singleRequestResolvesOnStatus() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  // The device answers with a real [1.5] STATUS: current 5, max 10, enabled.
  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 0x05, 0x03]))

  let reply = try await task.value
  #expect(reply.op == .status)
  let reading = try BmapNoiseCancellationReader.parse(reply)
  #expect(reading.currentStep == 5)
  await session.close()
}

@Test func singleRequestResolvesOnResult() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())
  let get = try BmapProductInfo.firmwareRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .firmwareVersion) == 1 })

  mock.deliver(try makeResult(.firmwareVersion, Array("1.0.0".utf8)))
  let reply = try await task.value
  #expect(reply.op == .result)
  await session.close()
}

@Test func singleRequestTurnsErrorIntoTypedError() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  mock.deliver(try makeError(.noiseCancellationRead, code: BmapErrorCode.functionNotSupported.rawValue))
  do {
    _ = try await task.value
    Issue.record("an ERROR frame did not surface as a typed error")
  } catch let error as BoseRequestError {
    #expect(error == .device(.functionNotSupported))
  }
  await session.close()
}

@Test func singleRequestPreservesUnknownErrorCode() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  // 99 is not a code this app names; the raw byte must still surface.
  mock.deliver(try makeError(.noiseCancellationRead, code: 99))
  do {
    _ = try await task.value
    Issue.record("an unknown ERROR code was swallowed")
  } catch let error as BoseRequestError {
    #expect(error == .deviceUnknown(rawCode: 99))
  }
  await session.close()
}

@Test func singleRequestTimesOutOnSilence() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock, settings: instantSettings(responseTimeout: .seconds(5))
  )
  let get = try BmapNoiseCancellationReader.readRequest()

  let task = Task { try await session.request(get) }
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  #expect(await eventually { await session.isAwaitingFrame })

  // No answer; advancing past the deadline fires the timeout on the injected clock.
  clock.advance(by: .seconds(5))
  do {
    _ = try await task.value
    Issue.record("a silent device did not time out")
  } catch let error as BoseRequestError {
    #expect(error == .timedOut)
  }
  await session.close()
}
