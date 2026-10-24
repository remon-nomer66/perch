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
