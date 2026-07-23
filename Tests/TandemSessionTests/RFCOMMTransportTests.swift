import Foundation
import Testing

@testable import TandemSession

@Test func aFailedOpenReturnsPromptlyAndTearsDown() async {
  // The address is synthetic — the locally administered bit is set — so no paired
  // device can match and the open fails on the lookup, before any radio traffic.
  // What is under test is the failure path itself: it must return rather than hang,
  // and it must leave the host in a state where further closes are harmless.
  let host = RFCOMMChannelHost(address: "02:1A:2B:3C:4D:5E")

  let start = ContinuousClock.now
  await #expect(throws: (any Error).self) {
    _ = try await host.open(timeout: .seconds(5))
  }
  #expect(ContinuousClock.now - start < .seconds(5), "the open ran into its timeout")

  // The failed open already tore down; closing again must be a no-op.
  host.close()
  host.close()
}

@Test func closingWithoutOpeningIsHarmless() {
  // The coordinator can ask for a close while an open is still being set up, so a
  // host must accept a close at any point in its life.
  let host = RFCOMMChannelHost(address: "02:1A:2B:3C:4D:5E")
  host.close()
  host.close()
}
