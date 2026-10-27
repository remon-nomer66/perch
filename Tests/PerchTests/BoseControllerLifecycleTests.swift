import Testing

@testable import Perch

// The controller's loop, stepped one tick at a time against scripted devices. The
// addresses are synthetic (documentation OUI 00:11:22); an output at …:55 is served by a
// BMAP address that shares its prefix, the way a single paired Bose product is.

private let output = "00-11-22-33-44-55"
private let control = "00-11-22-33-44-56"

/// A Bose device that leaves the audio output takes its readout with it. `teardown()` used
/// to leave the last `.ready` (name, battery) in place, so with no Sony device the panel
/// kept folding in a device that was gone — and, with `isBose` set and no panel model,
/// the settings window fell through to the Sony controls.
@MainActor
@Test func readoutGoesAwayWithTheDevice() async {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(controller.readout?.status == .ready)
  #expect(controller.readout?.modelName == "Model X")
  #expect(controller.panelModel != nil)

  audio.emit(.other)
  await controller.tick()
  #expect(controller.readout == nil)
  #expect(controller.panelModel == nil)
  #expect(controller.readoutAgreesWithPanel)
}

/// The same when the output stays Bluetooth but is no longer a Bose device: correlation
/// finds no control address, and nothing of the old device may be left on screen.
@MainActor
@Test func readoutGoesAwayWhenTheOutputMovesToAnotherMaker() async {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(controller.readout?.status == .ready)

  audio.emit(.identified(.init("aa-bb-cc-00-00-01")))
  await controller.tick()
  #expect(controller.readout == nil)
  #expect(controller.panelModel == nil)
}

/// An unreachable readout is the device's too: once the output is gone it must not stay
/// behind as "unreachable" any more than a ready one may.
@MainActor
@Test func unreachableReadoutGoesAwayWithTheOutput() async {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .refusesToOpen])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(controller.readout?.status == .unreachable)

  audio.emit(.other)
  await controller.tick()
  #expect(controller.readout == nil)
}

/// `stop()` is a teardown too, and leaves nothing to fold in.
@MainActor
@Test func stoppingClearsTheReadout() async {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(controller.readout?.status == .ready)

  await controller.stop()
  #expect(controller.readout == nil)
  #expect(controller.panelModel == nil)
}

/// `stop()` while a connect is still in flight. The tick carries on once its open returns;
/// stopping used to tear down underneath it, and the connect then put a session and a
/// readout back with nothing left to clear them.
@MainActor
@Test func stoppingMidConnectLeavesNothingBehind() async throws {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .readsBack])
  devices.holdsOpens = true
  let controller = BoseDeviceController(
    audio: audio, devices: devices, refreshInterval: .seconds(3600)
  )
  controller.start()
  while devices.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

  let stopping = Task { await controller.stop() }
  // Let `stop()` get as far as it will before the open returns.
  for _ in 0..<20 { await Task.yield() }
  devices.releaseOpens()
  await stopping.value

  // The resumed connect needs a few milliseconds at most to finish (every read on the
  // cancelled task fails at once); watch well past that for anything it puts back.
  let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
  while ContinuousClock.now < deadline {
    #expect(controller.readout == nil)
    #expect(controller.panelModel == nil)
    if controller.readout != nil || controller.panelModel != nil { break }
    try await Task.sleep(for: .milliseconds(10))
  }
}

// MARK: - Candidate rotation

/// Two BMAP addresses answer for one output (seen on hardware: one product published two,
/// and only the second worked). The first one opens but answers nothing. That is as much
/// a failure as a refused open and must hand the next tick the other candidate — it used
/// to be retried every tick for good, while only a refused open joined the rotation.
@MainActor
@Test func aCandidateThatOpensButAnswersNothingIsSetAside() async {
  let silent = "00-11-22-33-44-56"
  let answering = "00-11-22-33-44-57"
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([silent: .opensSilently, answering: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(devices.opened == [silent])
  #expect(controller.readout?.status == .unreachable)

  await controller.tick()
  #expect(devices.opened == [silent, answering])
  #expect(controller.readout?.status == .ready)
  #expect(controller.readoutAgreesWithPanel)
}

/// The refused open has always rotated; it must keep doing so.
@MainActor
@Test func aCandidateThatRefusesToOpenIsSetAside() async {
  let refusing = "00-11-22-33-44-56"
  let answering = "00-11-22-33-44-57"
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([refusing: .refusesToOpen, answering: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  await controller.tick()
  #expect(devices.opened == [refusing, answering])
  #expect(controller.readout?.status == .ready)
}

/// The scan's link facts reach correlation: of two Bose devices equally far from the
/// output, the one the Mac is linked to is tried first, though it is listed second.
@MainActor
@Test func theConnectedCandidateIsTriedFirst() async {
  let asleep = "00-11-22-a0-00-01"
  let linked = "00-11-22-b0-00-02"
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([asleep: .refusesToOpen, linked: .readsBack])
  devices.scanned = [candidate(asleep), candidate(linked, connected: true)]
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(devices.opened == [linked])
  #expect(controller.readout?.status == .ready)
}

/// Setting a silent candidate aside never silences the loop: with nothing else to try,
/// the rotation starts over and the same address is tried again — a bud that was in its
/// case may be out now.
@MainActor
@Test func aLoneSilentCandidateIsStillRetried() async {
  let audio = ScriptedAudioOutput(bluetooth: output)
  let devices = ScriptedBmapDevices([control: .opensSilently])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  await controller.tick()
  #expect(devices.opened == [control, control])
  #expect(controller.readout?.status == .unreachable)
}
