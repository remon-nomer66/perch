import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Helpers

/// Synthetic request and answer bytes: the channel is a double, so no device
/// vocabulary is involved.
private let markerRequest: [UInt8] = [0x0A, 0x01]
private let markerAnswer: [UInt8] = [0x0B, 0x01]

private func frame(_ payload: [UInt8]) -> @Sendable (UInt8) throws -> TandemFrame {
  { try TandemFrame(dataType: TandemFrame.table1DataType, sequence: $0, payload: Data(payload)) }
}

/// Noise control on the mode-select-with-adaptation inquiry (0x19): two ambient
/// modes, level 1...20, currently noise cancelling. The protocol's own codes; the
/// values are the test's.
private let noiseControlScript: [[UInt8]: [UInt8]] = [
  [0x60, 0x19]: [0x61, 0x19, 0x02, 0x00, 0x01, 0x14, 0x01, 0x01, 0x01, 0x14, 0x01],
  [0x66, 0x19]: [0x67, 0x19, 0x01, 0x01, 0x00, 0x00, 0x0A, 0x00, 0x00],
]

private func readySession(
  declaring codes: [UInt8] = [],
  script: [[UInt8]: [UInt8]] = [:],
  timeouts: SessionCoordinator.Timeouts
) async throws -> (SessionCoordinator, LinkDouble) {
  let opener = LinkOpener(script: script)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: codes)),
    timeouts: timeouts
  )
  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await coordinator.phase == .ready })
  return (coordinator, try #require(opener.latest))
}

// MARK: - Requests

@Test func aRequestWhoseWriteStallsStillTimesOut() async throws {
  // The response timeout was armed only once the write returned. A write held by flow
  // control never returns, so the request stayed in flight for good, and every request
  // queued behind it waited with it.
  let (coordinator, link) = try await readySession(
    timeouts: .init(response: .milliseconds(200), backoffUnit: .seconds(60), write: .seconds(60))
  )
  await link.stallWrites()

  let failed = Latch()
  let sender = Task {
    do {
      _ = try await coordinator.send(frame(markerRequest), matching: { _ in true })
    } catch {
      await failed.set()
    }
  }
  #expect(
    await waitFor(within: .seconds(3)) { await failed.isSet },
    "a stalled write left its request in flight forever"
  )
  sender.cancel()
  await coordinator.handle(.manualRelease)
}

// MARK: - Acknowledgements

@Test func aStalledAcknowledgementDoesNotHoldUpWhatArrivesNext() async throws {
  // Inbound processing awaited each acknowledgement it wrote. With that write stalled,
  // nothing after it was ever read — here, the answer the session is waiting for.
  let (coordinator, link) = try await readySession(
    timeouts: .init(response: .seconds(60), backoffUnit: .seconds(60), write: .seconds(60))
  )
  await link.stallAcknowledgements()

  let answered = Latch()
  let sender = Task {
    let answer = try await coordinator.send(
      frame(markerRequest),
      matching: { [UInt8]($0.payload) == markerAnswer }
    )
    if [UInt8](answer.payload) == markerAnswer { await answered.set() }
  }
  #expect(await waitFor { await link.writes(withPrefix: markerRequest) == 1 })

  // Something the device announces on its own, whose acknowledgement stalls, and then
  // the answer.
  try await link.send([0x0C, 0x00])
  try await link.send(markerAnswer)
  #expect(
    await waitFor(within: .seconds(3)) { await answered.isSet },
    "a stalled acknowledgement held up the answer behind it"
  )
  sender.cancel()
  await coordinator.handle(.manualRelease)
}

// MARK: - Writes without a reply

@Test func aDragStepWhoseWriteStallsReturnsAndRebuildsTheSession() async throws {
  // Intermediate drag values are written without waiting for an answer, and that write
  // had no bound at all: a stalled one never returned, so the drag — and whatever the
  // caller chained behind it — stopped for good on a channel nobody noticed was wedged.
  let (coordinator, link) = try await readySession(
    declaring: [0x6D],
    script: noiseControlScript,
    timeouts: .init(response: .seconds(60), backoffUnit: .seconds(60), write: .milliseconds(200))
  )
  #expect(await waitFor { await coordinator.readings.noiseControl != nil })
  await link.stallWrites()

  let returned = Latch()
  let target = TandemNoiseControlState(
    isActive: true, isNoiseCancelling: false, ambientMode: 0, ambientLevel: 5
  )
  let writer = Task {
    try? await coordinator.apply(noiseControl: target, isFinal: false)
    await returned.set()
  }
  #expect(
    await waitFor(within: .seconds(3)) { await returned.isSet },
    "a stalled drag step never returned"
  )
  #expect(
    await waitFor { await coordinator.phase == .retryWaiting },
    "the session kept a channel whose writes no longer complete"
  )
  writer.cancel()
  await coordinator.handle(.manualRelease)
}

// MARK: - The write chain

/// Records the order writes complete in. The write marked slow takes a while, the way
/// a write does while the remote is slow to grant credit.
private actor OrderRecordingChannel: TandemChannel {
  private let slow: Data
  private let hangs: Bool
  private(set) var written: [Data] = []

  init(slow: Data, hangs: Bool = false) {
    self.slow = slow
    self.hangs = hangs
  }

  func write(_ data: Data) async throws {
    if data == slow {
      try? await Task.sleep(for: hangs ? .seconds(3600) : .milliseconds(100))
    }
    written.append(data)
  }

  func close() async {}
}

@Test func writesReachTheChannelInTheOrderTheyWereQueued() async {
  // Acknowledgements and requests are queued from different places; the device must
  // still receive them in the order the session produced them, a slow one included.
  let first = Data([1])
  let channel = OrderRecordingChannel(slow: first)
  var chain = ChannelWriteChain()
  var outcomes: [ChannelWriteChain.Outcome] = []
  for data in [first, Data([2]), Data([3])] {
    let (next, outcome) = chain.appending(data, to: channel, within: .seconds(5))
    chain = next
    outcomes.append(outcome)
  }
  for outcome in outcomes {
    #expect((try? await outcome.value.get()) != nil)
  }
  #expect(await channel.written == [first, Data([2]), Data([3])])
}

@Test func aWriteThatOverrunsItsBoundFailsTypedWithoutWaitingForIt() async {
  let stuck = Data([1])
  let channel = OrderRecordingChannel(slow: stuck, hangs: true)
  let (_, outcome) = ChannelWriteChain().appending(stuck, to: channel, within: .milliseconds(100))
  let started = ContinuousClock.now
  guard case .failure(let failure) = await outcome.value else {
    Issue.record("a write that never returned was reported as done")
    return
  }
  #expect(failure == .writeTimedOut)
  #expect(ContinuousClock.now - started < .seconds(3), "the bound waited for the stalled write")
}
