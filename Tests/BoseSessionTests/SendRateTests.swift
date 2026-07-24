import BoseCore
import Foundation
import Testing

@testable import BoseSession

/// Consecutive sends closer than the settle window are spaced out on the injected
/// clock, so the test proves the throttle holds without waiting real time: the second
/// send does not reach the wire until the clock is advanced past the window.
@Test func settleWindowSpacesConsecutiveSends() async throws {
  let clock = TestSessionClock()
  let (session, mock) = await makeSession(
    clock: clock,
    settings: BoseSession.Settings(
      settleWindow: .milliseconds(90),
      responseTimeout: .seconds(60),
      maxReadBackPolls: 3
    )
  )

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

  // First send goes out immediately (the settle window starts empty).
  #expect(await eventually { await mock.sends(at: .noiseControlLiveWrite) == 1 })
  mock.deliver(try makeStatus(.noiseControlLiveWrite, [5, 0, 0, 0, 1]))

  // The read-back is now throttled: it is parked waiting for the settle window and has
  // not reached the wire.
  #expect(await eventually { await session.isThrottlingSend })
  #expect(await mock.sends(at: .noiseCancellationRead) == 0)

  // Advancing past the window releases the throttled send — on the clock, not in real time.
  clock.advance(by: .milliseconds(90))
  #expect(await eventually { await mock.sends(at: .noiseCancellationRead) == 1 })

  mock.deliver(try makeStatus(.noiseCancellationRead, [0x0b, 5, 0x03]))
  _ = try await task.value
  await session.close()
}
