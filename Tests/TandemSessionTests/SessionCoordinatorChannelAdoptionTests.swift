import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Synthetic request and answer bytes: the channel is a double, so no device
/// vocabulary is involved.
private let probeRequest: [UInt8] = [0x0A, 0x01]
private let probeAnswer: [UInt8] = [0x0B, 0x01]

@Test func anAbandonedOpenLandingWhileTheLiveOneVerifiesIsClosedNotAdopted() async throws {
  // The output moves from one device to another while the first open is still out.
  // The second open lands and starts verifying; then the first, abandoned open lands
  // too. The policy keeps `verifying` for the live attempt and asks for the stale
  // channel to be closed — but the phase alone looked like a live completion, so the
  // stale channel replaced the live one, the live reader was cancelled, and the live
  // RFCOMM channel was left open with nothing holding it.
  let opener = GatedLinkOpener(script: [probeRequest: probeAnswer])
  let verifier = HeldVerifier(outcome: try verifiedOutcome(declaring: []))
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: verifier,
    timeouts: SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .seconds(60))
  )

  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("device-a")))
  #expect(await waitFor { opener.links.count == 1 })
  await coordinator.handle(.defaultOutputChanged(DeviceIdentity("device-b")))
  #expect(await waitFor { opener.links.count == 2 })

  opener.release(1)
  #expect(await waitFor { await coordinator.phase == .verifying })
  let stale = opener.links[0]
  let live = opener.links[1]

  opener.release(0)
  #expect(await waitFor { await stale.isClosed }, "the abandoned channel was leaked")
  #expect(await live.isClosed == false, "the live channel was closed for the stale one")
  #expect(await coordinator.phase == .verifying)

  verifier.release()
  #expect(await waitFor { await coordinator.phase == .ready })
  // The session still talks over the live channel.
  let answer = try await coordinator.send(
    { try TandemFrame(dataType: TandemFrame.table1DataType, sequence: $0, payload: Data(probeRequest)) },
    matching: { [UInt8]($0.payload) == probeAnswer }
  )
  #expect([UInt8](answer.payload) == probeAnswer)

  // And releasing closes it: the session still owns it rather than having dropped it.
  await coordinator.handle(.manualRelease)
  #expect(await waitFor { await live.isClosed }, "the live channel was orphaned")
}
