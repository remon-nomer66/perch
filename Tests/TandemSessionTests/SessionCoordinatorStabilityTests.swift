import Foundation
import TandemCore
import Testing

@testable import TandemSession

// MARK: - Contention

@Test func aContendedSessionComesBackOnItsOwnOnceTheChannelIsFree() async throws {
  // The first open hangs to its deadline the way it does while another host holds the
  // control channel. Contention used to wait for the user; it now tries again slowly
  // and connects as soon as the channel is free.
  let opener = LinkOpener(timingOutFirst: 1)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: [])),
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(60),
      backoffUnit: .seconds(60),
      contentionRetry: .milliseconds(100)
    )
  )

  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await coordinator.phase == .contended })
  #expect(
    await waitFor(within: .seconds(3)) { await coordinator.phase == .ready },
    "contention never retried on its own"
  )
  await coordinator.handle(.manualRelease)
}

// MARK: - The failure budget across reconnects

@Test func aSessionThatFaultsOnItsFirstPollStopsReconnecting() async throws {
  // The device verifies, then never answers the battery it declared. Every reconnect
  // used to verify again and wipe the budget it had just spent, so the session cycled
  // ready → fault → reconnect forever and never reached exhaustion.
  let opener = LinkOpener()
  let coordinator = SessionCoordinator(
    policy: SessionPolicy(maximumFailureCount: 3),
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: [0x20])),
    timeouts: SessionCoordinator.Timeouts(
      response: .milliseconds(100),
      backoffUnit: .milliseconds(50)
    )
  )

  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(
    await waitFor(within: .seconds(5)) { await coordinator.phase == .retryExhausted },
    "a session that never settled kept reconnecting"
  )
  await coordinator.handle(.manualRelease)
}

@Test func aDeclaredReadTheDeviceNeverAnswersCostsOnlyThatReading() async throws {
  // The codec is declared but never answered. The battery is, so the session is
  // demonstrably alive: the silence must leave the codec empty and the session up,
  // not tear it down and reconnect on every poll.
  let opener = LinkOpener(script: [singleBatteryQuery: singleBatteryAnswer])
  var timeouts = SessionCoordinator.Timeouts(
    response: .milliseconds(100),
    backoffUnit: .milliseconds(20)
  )
  timeouts.readingIntervalOverride = .milliseconds(50)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: [0x20, 0x12])),
    timeouts: timeouts
  )

  await coordinator.handle(.defaultOutputChanged(linkTarget))
  #expect(await waitFor { await coordinator.readings.singleBattery == 50 })
  // Several poll cycles, each with an unanswered codec query.
  try await Task.sleep(for: .milliseconds(600))
  #expect(await coordinator.phase == .ready)
  #expect(opener.links.count == 1, "an unanswered optional read rebuilt the session")
  #expect(await coordinator.readings.codec == nil)
  await coordinator.handle(.manualRelease)
}

@Test func aSessionThatProvedItselfSurvivesRepeatedDrops() async throws {
  // The other half of the contract: a session whose first poll completed has proved
  // itself, so a later drop — a wearing change — starts the budget over. With a
  // budget of two, four drops in a row would otherwise end at exhaustion.
  let opener = LinkOpener(script: [singleBatteryQuery: singleBatteryAnswer])
  let coordinator = SessionCoordinator(
    policy: SessionPolicy(maximumFailureCount: 2),
    opener: opener,
    verifier: FixedOutcomeVerifier(outcome: try verifiedOutcome(declaring: [0x20])),
    timeouts: SessionCoordinator.Timeouts(
      response: .seconds(60),
      backoffUnit: .milliseconds(20)
    )
  )

  await coordinator.handle(.defaultOutputChanged(linkTarget))
  for drop in 1...4 {
    #expect(
      await waitFor {
        let snapshot = await coordinator.snapshot
        return snapshot.phase == .ready && snapshot.readings.singleBattery == 50
      },
      "reconnect \(drop) never settled"
    )
    // Exhaustion re-arms on a slow cadence and would reconnect too, so the budget
    // itself is what shows the drops were forgiven.
    #expect(
      await waitFor { await coordinator.failureCount == 0 },
      "a settled session kept the budget its reconnect spent"
    )
    await opener.latest?.drop()
    #expect(await waitFor { opener.links.count == drop + 1 }, "drop \(drop) did not reconnect")
  }
  #expect(await waitFor { await coordinator.phase == .ready })
  await coordinator.handle(.manualRelease)
}
