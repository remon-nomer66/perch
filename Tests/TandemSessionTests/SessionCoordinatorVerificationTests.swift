import Foundation
import TandemCore
import Testing

@testable import TandemSession

/// Stands in for a verification whose conversation fails with `error`.
private struct FailingVerifier: DeviceVerifying {
  let error: any Error & Sendable

  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    throw error
  }
}

private func coordinator(
  failingWith error: any Error & Sendable,
  opener: LinkOpener
) -> SessionCoordinator {
  SessionCoordinator(
    opener: opener,
    verifier: FailingVerifier(error: error),
    timeouts: SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .milliseconds(20))
  )
}

// MARK: - Classification

@Test func anUnreadableHandshakeAnswerIsDeterministic() {
  // The device answered; the answer has the wrong shape. Nothing about asking again
  // changes the shape.
  for error: any Error in [
    TandemHandshakeError.invalidProtocolPayloadLength(3),
    TandemHandshakeError.invalidSupportCount(declared: 4, actual: 2),
    TandemHandshakeError.unexpectedCommand(0x7F),
  ] {
    #expect(VerificationFailureKind(error) == .deterministic, "\(error)")
  }
}

@Test func failingToReachTheDeviceIsTransient() {
  for error: any Error in [
    SessionRequestFailure.failed(.noReply),
    SessionRequestFailure.failed(.sessionInvalidated),
    SessionRequestFailure.notReady,
    SessionRequestFailure.channel(.closed),
    ChannelFailure.writeTimedOut,
    CancellationError(),
  ] {
    #expect(VerificationFailureKind(error) == .transient, "\(error)")
  }
}

// MARK: - The session

@Test func anUnreadableHandshakeParksTheSessionInsteadOfRetrying() async throws {
  let opener = LinkOpener()
  let session = coordinator(
    failingWith: TandemHandshakeError.invalidProtocolPayloadLength(3),
    opener: opener
  )
  await session.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await session.phase == .incompatible })

  // Long enough for several backoffs at this unit; none may fire a reconnect beyond
  // the one that checks the first answer was not a fluke.
  try await Task.sleep(for: .milliseconds(300))
  #expect(await session.phase == .incompatible)
  #expect(opener.links.count == 2, "a deterministic failure was retried")
  for link in opener.links {
    #expect(await link.isClosed, "the control channel was held for nothing")
  }
  await session.handle(.manualRelease)
}

@Test func aVerificationThatCouldNotReachTheDeviceStillRetries() async throws {
  let opener = LinkOpener()
  let session = coordinator(failingWith: SessionRequestFailure.failed(.noReply), opener: opener)
  await session.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { opener.links.count >= 2 }, "a transient failure was not retried")
  await session.handle(.manualRelease)
}
