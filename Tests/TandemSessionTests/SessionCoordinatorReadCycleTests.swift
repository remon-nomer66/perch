import Foundation
import TandemCore
import Testing

@testable import TandemSession

// The protocol's own command and inquiry codes; every value is the test's own. The
// equaliser has two bands and presets 0x00 and 0xA0, and starts on 0xA0.
private let equalizerScript: [[UInt8]: [UInt8]] = [
  [0x50, 0x04]: [0x51, 0x04, 2, 11, 2, 0x00, 0, 0xA0, 0],
  [0x56, 0x04]: [0x57, 0x04, 0xA0, 2, 5, 7],
  [0x5A, 0x04]: [0x5B, 0x04, 2, 0, 0x01, 0x90, 0, 0x03, 0xE8],
]
/// The equaliser after the write under test took effect.
private let equalizerAfterWrite: [UInt8] = [0x57, 0x04, 0x00, 2, 5, 7]
private let speakToChat = TandemSpeakToChatProtocol.inquiryType2
private let speakToChatCapability: [UInt8] = [0xF1, speakToChat, 1, 10, 20, 30]
private let speakToChatScript: [[UInt8]: [UInt8]] = [
  [0xF0, speakToChat]: speakToChatCapability,
  [0xF6, speakToChat]: [0xF7, speakToChat, 0x00, 0x01],
  [0xFA, speakToChat]: [0xFB, speakToChat, 0x01, 0x02],
]
/// A different detail answer, so the test can see when a later cycle has stored.
private let laterSpeakToChatDetail: [UInt8] = [0xFB, speakToChat, 0x02, 0x00]

@Test func aPollCycleUnderWayDoesNotPutBackAValueAWriteJustConfirmed() async throws {
  // The poll reads the equaliser early in its cycle and stores everything at the end.
  // A write that lands in between confirms its value — and then the cycle's store,
  // holding the value read before the write, put the old one back until the next
  // cycle, twenty seconds later.
  let opener = LinkOpener(script: equalizerScript.merging(speakToChatScript) { $1 })
  var timeouts = SessionCoordinator.Timeouts(response: .seconds(60), backoffUnit: .seconds(60))
  timeouts.readingIntervalOverride = .milliseconds(300)
  let coordinator = SessionCoordinator(
    opener: opener,
    verifier: FixedOutcomeVerifier(
      outcome: try verifiedOutcome(declaring: [0x57, TandemSpeakToChatProtocol.functionCodeType2])
    ),
    timeouts: timeouts
  )
  await coordinator.handle(.defaultOutputChanged(linkTarget))
  // The first cycle stores, which is what makes the equaliser writable at all.
  #expect(
    await waitFor {
      let readings = await coordinator.readings
      return readings.equalizer != nil && readings.speakToChat != nil
    }
  )
  let link = try #require(opener.latest)
  let firstSpeakToChat = await coordinator.readings.speakToChat

  // The next cycle reads the equaliser and is then held at speak-to-chat, which the
  // device answers only when the test says so.
  await link.answer([0xF0, speakToChat], with: nil)
  await link.answer([0xFA, speakToChat], with: laterSpeakToChatDetail)
  #expect(await waitFor { await link.writes(withPrefix: [0xF0, speakToChat]) == 2 })
  await link.answer([0x56, 0x04], with: equalizerAfterWrite)

  // The set goes out at once; its read-back queues behind the held read.
  let writer = Task { try await coordinator.apply(equalizerPreset: 0x00, bandSteps: []) }
  #expect(await waitFor { await link.writes(withPrefix: [0x58, 0x04]) == 1 })
  try await link.send(speakToChatCapability)
  try await writer.value
  #expect(await coordinator.readings.equalizer?.selectedPreset == 0x00)

  // The held cycle then finishes and stores what it read.
  #expect(await waitFor { await coordinator.readings.speakToChat != firstSpeakToChat })
  #expect(
    await coordinator.readings.equalizer?.selectedPreset == 0x00,
    "the poll put back the value it read before the write"
  )
  await coordinator.handle(.manualRelease)
}

// MARK: - Merging a cycle's result

private func noiseControl(level: Int) -> NoiseControlReading {
  NoiseControlReading(
    inquiry: 0x19,
    modes: [],
    state: TandemNoiseControlState(
      isActive: true, isNoiseCancelling: false, ambientMode: 0, ambientLevel: level
    )
  )
}

@Test func onlyTheSettingsChangedDuringACycleAreKeptFromBefore() {
  var current = DeviceReadings()
  current.noiseControl = noiseControl(level: 9)
  current.singleBattery = 40
  var polled = DeviceReadings()
  polled.noiseControl = noiseControl(level: 3)
  polled.singleBattery = 50

  let started = SettingRevisions()
  let afterWrite = started.bumping(.noiseControl)
  let changed = afterWrite.settingsChanged(since: started)
  #expect(changed == [.noiseControl])

  let merged = polled.keeping(changed, from: current)
  #expect(merged.noiseControl == noiseControl(level: 9), "the written value was lost")
  #expect(merged.singleBattery == 50, "a value only the poll reads was held back")
  #expect(polled.keeping([], from: current) == polled)
}

@Test func eachSettingIsKeptOnItsOwn() {
  // Keeping one setting must not drag a neighbour along with it.
  var current = DeviceReadings()
  current.noiseControl = noiseControl(level: 9)
  current.equalizer = EqualizerReading(
    presets: [], selectedPreset: 0xA0, bandFrequencies: [0], bandSteps: [5],
    stepRange: 0...10, flatStep: 5
  )

  let keptNoise = DeviceReadings().keeping([.noiseControl], from: current)
  #expect(keptNoise.noiseControl == current.noiseControl)
  #expect(keptNoise.equalizer == nil)

  let keptEqualizer = DeviceReadings().keeping([.equalizer], from: current)
  #expect(keptEqualizer.equalizer == current.equalizer)
  #expect(keptEqualizer.noiseControl == nil)
}
