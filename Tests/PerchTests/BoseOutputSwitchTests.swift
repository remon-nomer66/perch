import Foundation
import TandemSession
import Testing

@testable import Perch

// Re-evaluating the correlation when the default output moves. Addresses are synthetic
// (documentation OUI 00:11:22): two headphones, each its own control address.

private let first = "00-11-22-33-44-55"
private let second = "00-11-22-77-88-99"

/// Moving the output from one Bose device to another moves the session with it. The
/// session must not stay pinned to the device that stopped playing while the panel's
/// writes keep landing on it.
@MainActor
@Test func switchingBetweenBoseDevicesMovesTheSession() async {
  let audio = ScriptedAudioOutput(bluetooth: first)
  let devices = ScriptedBmapDevices([first: .readsBack, second: .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  #expect(devices.opened == [first])

  audio.emit(.identified(DeviceIdentity(second)))
  await controller.tick()
  #expect(devices.opened == [first, second])
  #expect(controller.readout?.status == .ready)
}

/// A switch is acted on when it is reported, not at the next poll. Until the loop looks
/// again the panel still drives the old device, so a gesture in that window writes to
/// headphones nobody is listening to. The poll interval here is an hour: only the switch
/// event can explain a second open.
@MainActor
@Test func anOutputSwitchWakesTheLoop() async throws {
  let audio = ScriptedAudioOutput(bluetooth: first)
  let devices = ScriptedBmapDevices([first: .readsBack, second: .readsBack])
  let controller = BoseDeviceController(
    audio: audio, devices: devices, refreshInterval: .seconds(3600)
  )
  controller.start()

  try await eventually { controller.readout?.status == .ready }
  #expect(devices.opened == [first])

  audio.emit(.identified(DeviceIdentity(second)))
  try await eventually { devices.opened == [first, second] }

  await controller.stop()
}

/// The same right after a connect, and away from Bose altogether: moving the output to the
/// speakers takes the device off the panel at once. The connect's own teardown used to
/// clear the identity a switch is judged against, so in the poll after a connect a move
/// to the speakers looked like no change and woke nothing.
@MainActor
@Test func aSwitchToTheSpeakersRightAfterAConnectWakesTheLoop() async throws {
  let audio = ScriptedAudioOutput(bluetooth: first)
  let devices = ScriptedBmapDevices([first: .readsBack])
  let controller = BoseDeviceController(
    audio: audio, devices: devices, refreshInterval: .seconds(3600)
  )
  controller.start()

  try await eventually { controller.readout?.status == .ready }

  audio.emit(.other)
  try await eventually { controller.readout == nil }
  #expect(controller.panelModel == nil)

  await controller.stop()
}

/// Only a change of *device* is a switch. Core Audio also reports the same output again,
/// and waking for that would rerun the synchronous SDP scan — or reopen a channel the
/// device just refused — for nothing.
@Test func onlyADifferentDeviceCountsAsASwitch() {
  let observed = DeviceIdentity(first).rawValue
  let isSwitch = BoseDeviceController.isSwitch(to:awayFrom:)

  #expect(!isSwitch(.identified(DeviceIdentity(first)), observed))
  #expect(isSwitch(.identified(DeviceIdentity(second)), observed))
  #expect(isSwitch(.other, observed))
  #expect(isSwitch(.unidentifiedBluetooth(uid: "unidentified"), observed))
  // Last seen on the speakers: a Bluetooth device appearing is a switch, the speakers
  // reported again are not.
  #expect(isSwitch(.identified(DeviceIdentity(first)), nil))
  #expect(!isSwitch(.other, nil))
}

/// Polls `condition` until it holds, failing after `timeout`. For the loop's own task,
/// whose progress a test can only observe, never step.
@MainActor
private func eventually(
  timeout: Duration = .seconds(5),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("condition did not hold within \(timeout)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
