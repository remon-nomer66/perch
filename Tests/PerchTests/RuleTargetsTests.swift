import Testing
import TandemCore
import TandemSession

@testable import Perch

/// The rule engine's pure decision core: which device state a rule action asks for,
/// given what the device declared. No session, no device.

private func noiseReading(
  inquiry: UInt8 = 0x17,
  state: TandemNoiseControlState = TandemNoiseControlState(
    isActive: true, isNoiseCancelling: true, ambientMode: 0, ambientLevel: 10
  )
) -> NoiseControlReading {
  NoiseControlReading(
    inquiry: inquiry,
    modes: [TandemAmbientModeCapability(mode: 0, minimumLevel: 1, maximumLevel: 20, step: 1)],
    state: state
  )
}

@Test("Keep asks for nothing")
@MainActor
func keepAsksForNothing() {
  #expect(AppModel.noiseTarget(.keep, noiseReading()) == nil)
  let listening = TandemListeningReading(features: [], selection: .standard, savedRoom: .middle)
  #expect(AppModel.listeningTarget(.keep, listening) == nil)
}

@Test("Noise actions keep the current ambient mode and level")
@MainActor
func noiseTargetsPreserveAmbientSettings() {
  let reading = noiseReading(
    state: TandemNoiseControlState(
      isActive: false, isNoiseCancelling: false, ambientMode: 1, ambientLevel: 7
    )
  )

  let cancelling = AppModel.noiseTarget(.noiseCancelling, reading)
  #expect(cancelling?.isActive == true)
  #expect(cancelling?.isNoiseCancelling == true)
  #expect(cancelling?.ambientMode == 1)
  #expect(cancelling?.ambientLevel == 7)

  let ambient = AppModel.noiseTarget(.ambient, reading)
  #expect(ambient?.isActive == true)
  #expect(ambient?.isNoiseCancelling == false)
  #expect(ambient?.ambientLevel == 7)

  let off = AppModel.noiseTarget(.off, reading)
  #expect(off?.isActive == false)
  #expect(off?.ambientLevel == 7)
}

@Test("A dialect without the asked-for mode yields no target")
@MainActor
func missingModesYieldNoTarget() {
  // 0x21 is ambient-only: no noise cancelling to ask for.
  let ambientOnly = noiseReading(inquiry: 0x21)
  #expect(AppModel.noiseTarget(.noiseCancelling, ambientOnly) == nil)
  #expect(AppModel.noiseTarget(.ambient, ambientOnly) != nil)

  // 0x01 only toggles noise cancelling: no ambient sound to ask for.
  let noiseCancellingOnly = noiseReading(inquiry: 0x01)
  #expect(AppModel.noiseTarget(.ambient, noiseCancellingOnly) == nil)
  #expect(AppModel.noiseTarget(.noiseCancelling, noiseCancellingOnly) != nil)

  // Off exists in every dialect.
  #expect(AppModel.noiseTarget(.off, ambientOnly) != nil)
}

@Test("Listening targets follow the declared features and remember the room")
@MainActor
func listeningTargetsFollowDeclaredFeatures() {
  let bgm = TandemListeningFeature(function: 0x01, inquiry: 0x01, kind: .backgroundMusic)
  let cinema = TandemListeningFeature(function: 0x02, inquiry: 0x02, kind: .cinema)
  let both = TandemListeningReading(
    features: [bgm, cinema], selection: .standard, savedRoom: .large
  )

  #expect(AppModel.listeningTarget(.standard, both) == .standard)
  #expect(AppModel.listeningTarget(.backgroundMusic, both) == .backgroundMusic(.large))
  #expect(AppModel.listeningTarget(.cinema, both) == .cinema)

  // A device declaring neither mode cannot be asked for them.
  let none = TandemListeningReading(features: [], selection: .standard, savedRoom: .middle)
  #expect(AppModel.listeningTarget(.backgroundMusic, none) == nil)
  #expect(AppModel.listeningTarget(.cinema, none) == nil)
  #expect(AppModel.listeningTarget(.standard, none) == .standard)
}
