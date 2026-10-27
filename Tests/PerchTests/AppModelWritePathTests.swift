import Foundation
import TandemCore
import TandemSession
import Testing

@testable import Perch

// AppModel's write path, wired to a real SessionService whose system observers and
// channel opener are inert. The session is never started and stays released — no
// Bluetooth, no control channel — so every write is refused at once. That is all these
// need: they check what the model does around a write (which refresh follows it, which
// guard it holds and lifts), not what the device does with it.

private struct NoChannels: TandemChannelOpening {
  func open(_ device: DeviceIdentity) async throws -> OpenedChannel {
    throw CancellationError()
  }
}

private struct NoVerification: DeviceVerifying {
  func verify(over requests: SessionRequesting) async throws -> VerificationOutcome {
    throw CancellationError()
  }
}

private struct NoAudioOutput: AudioOutputObserving {
  var changes: AsyncStream<AudioOutput> { AsyncStream { $0.finish() } }
  func start() {}
  func stop() {}
  func current() -> AudioOutput { .other }
}

private struct NoBluetooth: BluetoothConnectionObserving {
  var changes: AsyncStream<BluetoothConnectionObserver.Change> { AsyncStream { $0.finish() } }
  func start() {}
  func stop() {}
}

private struct NoPower: PowerObserving {
  var changes: AsyncStream<PowerObserver.Change> { AsyncStream { $0.finish() } }
  func start() {}
  func stop() {}
}

private func deviceLessService() -> SessionService {
  SessionService(
    coordinator: SessionCoordinator(opener: NoChannels(), verifier: NoVerification()),
    audio: NoAudioOutput(),
    bluetooth: NoBluetooth(),
    power: NoPower()
  )
}

/// An ambient-sound reading with an adjustable level, as a device would report it.
private let ambientReading = NoiseControlReading(
  inquiry: 0x17,
  modes: [TandemAmbientModeCapability(mode: 0, minimumLevel: 0, maximumLevel: 20, step: 1)],
  state: TandemNoiseControlState(
    isActive: true, isNoiseCancelling: false, ambientMode: 0, ambientLevel: 5
  )
)

@MainActor
@Test("A device write's read-back keeps the track the panel shows")
func writeReadBackKeepsTheTrack() async {
  let model = AppModel()
  let service = deviceLessService()
  await model.refresh(from: service, cause: .deviceWrite)
  let track = PanelModel.NowPlaying(title: "T", artist: "A", isPlaying: true, artworkURL: nil)
  model.panel.nowPlaying = track

  model.applyNoiseControl(ambientReading.state, using: service)
  await model.settleDeviceWrites()

  // Had the read-back asked the players — here not allowed to answer — the track would
  // be gone, and a headphone tap now would go out as a system media key.
  #expect(model.panel.nowPlaying == track)
}

@MainActor
@Test("An intermediate drag value keeps its field guarded; only the final read-back lifts it")
func onlyTheFinalLiftsADragsGuard() async {
  let timer = ManualTimer()
  let model = AppModel(dragSleep: timer.sleep)
  let service = deviceLessService()
  await model.refresh(from: service, cause: .deviceWrite)
  model.panel.noiseControl = ambientReading

  model.dragNoiseLevel(level: 12, isFinal: false, using: service)
  let dragged = model.panel.noiseControl
  #expect(dragged?.state.ambientLevel == 12)

  // The pointer pauses: the value goes out as an intermediate write.
  await waitUntil { timer.pending == 1 }
  timer.fire()
  await waitUntil { timer.pending == 1 }
  await model.settleDeviceWrites()
  // The released session reads nothing back: an unguarded field would now be empty.
  await model.refresh(from: service, cause: .periodic)
  #expect(model.panel.noiseControl == dragged)

  model.dragNoiseLevel(level: 12, isFinal: true, using: service)
  await model.settleDeviceWrites()
  await model.refresh(from: service, cause: .periodic)
  #expect(model.panel.noiseControl == nil)
  await timer.drain()
}

@MainActor
@Test("A release left unsent after the drag settled on its own leaves nothing guarded")
func skippedReleaseLeavesTheFieldUnguarded() async {
  let timer = ManualTimer()
  let model = AppModel(dragSleep: timer.sleep)
  let service = deviceLessService()
  await model.refresh(from: service, cause: .deviceWrite)
  model.panel.noiseControl = ambientReading

  model.dragNoiseLevel(level: 12, isFinal: false, using: service)
  await waitUntil { timer.pending == 1 }
  timer.fire()  // the pause: an intermediate write
  await waitUntil { timer.pending == 1 }
  timer.fire()  // the quiet spell: finalised where it stopped
  await yieldToMainActor()
  await model.settleDeviceWrites()

  // Released without moving since: the same final is not sent again. Skipping it must
  // not strand a guard — had the release taken a token whose write never came, the
  // field would stay frozen on the dragged value for a whole lease.
  model.dragNoiseLevel(level: 12, isFinal: true, using: service)
  await model.settleDeviceWrites()
  await model.refresh(from: service, cause: .periodic)
  #expect(model.panel.noiseControl == nil)
  await timer.drain()
}

@MainActor
@Test("A switch's write lifts its guard once read back")
func switchWriteLiftsItsGuard() async {
  let model = AppModel()
  let service = deviceLessService()
  await model.refresh(from: service, cause: .deviceWrite)
  let capability = TandemGeneralSettingCapability(
    slot: .one,
    type: .boolean,
    label: TandemGeneralString(format: .enumName, title: "SIDETONE_SETTING", summary: ""),
    listValues: []
  )
  model.panel.sidetone = SidetoneReading(
    slot: .one,
    snapshot: TandemGeneralSettingSnapshot(
      capability: capability, isControlEnabled: true, value: .boolean(false)
    )
  )

  model.applySidetone(enabled: true, using: service)
  // Guarded while in flight: the refresh leaves the optimistic switch alone.
  await model.refresh(from: service, cause: .periodic)
  #expect(model.panel.sidetone?.isEnabled == true)

  await model.settleDeviceWrites()
  await model.refresh(from: service, cause: .periodic)
  #expect(model.panel.sidetone == nil)
}
