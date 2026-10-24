import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Synthetic request and answer bytes: the channel is a double, so no device
/// vocabulary is involved. The first request is never answered.
private let unansweredRequest: [UInt8] = [0x0A, 0x01]
private let answeredRequest: [UInt8] = [0x0A, 0x02]
private let answer: [UInt8] = [0x0B, 0x02]

private func frame(_ payload: [UInt8]) -> @Sendable (UInt8) throws -> TandemFrame {
  { try TandemFrame(dataType: TandemFrame.table1DataType, sequence: $0, payload: Data(payload)) }
}

@Test func aRequestLeftOnAnExpiredGraceFailsAtOnceAndCannotFaultTheNextSession() async throws {
  // The grace expiring invalidated the session without failing the request still on
  // the wire. That request held the wire until its own timeout, and the timeout then
  // faulted whichever session was live by then — here, the reconnect that followed.
  let opener = LinkOpener(script: [answeredRequest: answer])
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: [])),
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(1),
      grace: .milliseconds(100),
      backoffUnit: .seconds(60)
    )
  )
  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await coordinator.phase == .ready })
  let first = try #require(opener.latest)

  let failure = Latch()
  let stranded = Task {
    do {
      _ = try await coordinator.send(frame(unansweredRequest), matching: { _ in false })
    } catch SessionRequestFailure.failed(.sessionInvalidated) {
      await failure.set()
    }
  }
  #expect(await waitFor { await first.writes(withPrefix: unansweredRequest) == 1 })

  await coordinator.handle(.defaultOutputChanged(nil))
  #expect(await waitFor { await coordinator.phase == .released })
  #expect(
    await waitFor(within: .milliseconds(500)) { await failure.isSet },
    "the request outlived the session it was sent on"
  )

  // The reconnect talks freely, and outlives the old request's deadline.
  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await coordinator.phase == .ready })
  let reply = try await coordinator.send(frame(answeredRequest), matching: { [UInt8]($0.payload) == answer })
  #expect([UInt8](reply.payload) == answer)
  try await Task.sleep(for: .milliseconds(1200))
  #expect(await coordinator.phase == .ready, "an old request's timeout faulted the new session")

  stranded.cancel()
  await coordinator.handle(.manualRelease)
}
