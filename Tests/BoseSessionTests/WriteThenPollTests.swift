import BoseCore
import Foundation
import Testing

@testable import BoseSession

/// A realistic Ultra 2 flow: write the level via [31.10] SETGET, then read it back via
/// a [1.5] GET and confirm the reported step matches.
@Test func writeThenPollConfirmsAppliedValue() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())

  let write = try BmapNoiseControlLiveWrite.writeRequest(
    BmapNoiseControlSetting(cnc: 5, spatial: .off, windBlock: false, ancEnabled: true)
  )
  let readBack = try BmapNoiseCancellationReader.readRequest()

  let task = Task {
    try await session.writeThenPoll(
      write: write,
      readBack: readBack,
      isApplied: { (try? BmapNoiseCancellationReader.parse($0))?.currentStep == 5 }
    )
  }

  // Phase 1: the SETGET echo.
  #expect(await eventually { await mock.sends(at: .noiseControlLiveWrite) == 1 })
  mock.deliver(try makeStatus(.noiseControlLiveWrite, [5, 0, 0, 0, 1]))

  // Phase 2: the read-back GET runs and reports the written step.
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })
  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 5, 0x03]))

  let confirmed = try await task.value
  #expect(confirmed.address == .noiseCancellationRead)
  #expect(try BmapNoiseCancellationReader.parse(confirmed).currentStep == 5)
  await session.close()
}

@Test func writeThenPollReportsNotAppliedOnMismatch() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings(maxReadBackPolls: 3))

  let write = try BmapNoiseControlLiveWrite.writeRequest(
    BmapNoiseControlSetting(cnc: 5, spatial: .off, windBlock: false, ancEnabled: true)
  )
  let readBack = try BmapNoiseCancellationReader.readRequest()

  let task = Task {
    try await session.writeThenPoll(
      write: write,
      readBack: readBack,
      isApplied: { (try? BmapNoiseCancellationReader.parse($0))?.currentStep == 5 }
    )
  }

  #expect(await eventually { await mock.sends(at: .noiseControlLiveWrite) == 1 })
  mock.deliver(try makeStatus(.noiseControlLiveWrite, [5, 0, 0, 0, 1]))

  // The device keeps reporting step 3, never the requested 5, for every read-back.
  for poll in 1...3 {
    #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == poll })
    mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 3, 0x03]))
  }

  do {
    _ = try await task.value
    Issue.record("a value that never took was reported as applied")
  } catch let error as BoseRequestError {
    guard case .notApplied(let frame) = error else {
      Issue.record("expected notApplied, got \(error)")
      return
    }
    #expect(try BmapNoiseCancellationReader.parse(frame).currentStep == 3)
  }
  // The read-back ran exactly the capped number of times.
  #expect(await mock.sends(at: .noiseCancellationRead) == 3)
  await session.close()
}

@Test func writeThenPollSurfacesWriteError() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(clock: clock, settings: instantSettings())

  let write = try BmapNoiseControlLiveWrite.writeRequest(
    BmapNoiseControlSetting(cnc: 5, spatial: .off, windBlock: false, ancEnabled: true)
  )
  let readBack = try BmapNoiseCancellationReader.readRequest()

  let task = Task {
    try await session.writeThenPoll(write: write, readBack: readBack, isApplied: { _ in true })
  }
  #expect(await eventually { await mock.sends(at: .noiseControlLiveWrite) == 1 })

  // The write itself is refused (a locked write): the read-back must never run.
  mock.deliver(try makeError(.noiseControlLiveWrite, code: BmapErrorCode.runtime.rawValue))
  do {
    _ = try await task.value
    Issue.record("a refused write did not surface")
  } catch let error as BoseRequestError {
    #expect(error == .device(.runtime))
  }
  #expect(await mock.sends(at: .noiseCancellationRead) == 0)
  await session.close()
}
