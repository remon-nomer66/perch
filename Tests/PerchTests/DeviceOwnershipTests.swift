import BoseCore
import BosePanel
import Testing

@testable import Perch

// Which brand owns the screens, and whose controls they draw. One decision, read by the
// notch and the settings window alike, so the two cannot disagree (#10).

private let boseReady = BoseDeviceController.Readout(
  status: .ready, modelName: "Model X", firmwareVersion: nil, battery: .single(80)
)

private func sony(_ status: DeviceSummary.Status) -> PanelModel {
  var panel = PanelModel()
  panel.summary.status = status
  panel.summary.modelName = status == .noDevice ? nil : "Sony"
  return panel
}

// MARK: - Ownership

@Test func sonyKeepsThePanelWhileItIsControllable() {
  let panel = sony(.ready).foldingIn(bose: boseReady)
  #expect(!panel.isBose)
  #expect(panel.summary.modelName == "Sony")
}

@Test func boseOwnsThePanelWhenSonyHasNothing() {
  let panel = sony(.noDevice).foldingIn(bose: boseReady)
  #expect(panel.isBose)
  #expect(panel.summary.status == .ready)
  #expect(panel.summary.modelName == "Model X")
  #expect(panel.summary.acceptsWrites)
  #expect(panel.battery == .single(80))
}

/// Bose owns the panel while it is still connecting or has failed, too: the header then
/// says so, instead of "no device".
@Test func boseOwnsThePanelWhileUnreachable() {
  let unreachable = BoseDeviceController.Readout(
    status: .unreachable, modelName: nil, firmwareVersion: nil, battery: .unknown
  )
  let panel = sony(.noDevice).foldingIn(bose: unreachable)
  #expect(panel.isBose)
  #expect(panel.summary.status == .unreachable)
}

@Test func withoutAReadoutNobodyIsBose() {
  let panel = sony(.noDevice).foldingIn(bose: nil)
  #expect(!panel.isBose)
  #expect(panel.summary.status == .noDevice)
}

// MARK: - Whose controls are drawn

@MainActor
@Test func aLiveBosePanelDrawsBoseControls() {
  let panel = sony(.noDevice).foldingIn(bose: boseReady)
  let controls = DeviceControls(panel: panel, bosePanel: BosePanelModel(config: .qcUltra2))
  #expect(controls.isBose)
  #expect(!controls.drawsSonyPages)
}

@MainActor
@Test func aControllableSonyDrawsSonyControls() {
  let controls = DeviceControls(panel: sony(.ready), bosePanel: nil)
  #expect(controls == .sony)
  #expect(controls.drawsSonyPages)
}

/// The #10 mismatch: Bose owning the panel while its readout said `.ready` and no live
/// panel was behind it. Judged by "is anything controllable", the settings window drew
/// Sony's controls there, under a header showing the Bose device. Bose ownership without
/// a live panel draws neither brand's controls, whatever the summary says.
@MainActor
@Test func boseOwnershipWithoutALivePanelNeverDrawsSony() {
  let panel = sony(.noDevice).foldingIn(bose: boseReady)
  #expect(panel.summary.isControllable)

  let controls = DeviceControls(panel: panel, bosePanel: nil)
  #expect(controls == .neither)
  #expect(!controls.drawsSonyPages)
}

@MainActor
@Test func nothingControllableDrawsNeither() {
  let controls = DeviceControls(panel: sony(.unreachable), bosePanel: nil)
  #expect(controls == .neither)
  #expect(!controls.drawsSonyPages)
}

/// Sony being controllable wins even with a live Bose session open alongside it — the
/// two can both be live, and only the panel's owner draws.
@MainActor
@Test func aLiveBoseSessionDoesNotOverruleSony() {
  let panel = sony(.ready).foldingIn(bose: boseReady)
  let controls = DeviceControls(panel: panel, bosePanel: BosePanelModel(config: .qcUltra2))
  #expect(controls == .sony)
}

// MARK: - End to end

/// The controller's readout through to what the screens draw: once the Bose device leaves
/// the output there is nothing left to own the panel, so neither the Bose controls nor —
/// the #10 fall-through — the Sony ones are drawn.
@MainActor
@Test func aDeviceLeavingTheOutputLeavesNoOwnerBehind() async {
  let audio = ScriptedAudioOutput(bluetooth: "00-11-22-33-44-55")
  let devices = ScriptedBmapDevices(["00-11-22-33-44-56": .readsBack])
  let controller = BoseDeviceController(audio: audio, devices: devices)

  await controller.tick()
  let owned = sony(.noDevice).foldingIn(bose: controller.readout)
  #expect(owned.isBose)
  #expect(DeviceControls(panel: owned, bosePanel: controller.panelModel).isBose)

  audio.emit(.other)
  await controller.tick()
  let left = sony(.noDevice).foldingIn(bose: controller.readout)
  #expect(!left.isBose)
  #expect(left.summary.status == .noDevice)
  #expect(DeviceControls(panel: left, bosePanel: controller.panelModel) == .neither)
}
