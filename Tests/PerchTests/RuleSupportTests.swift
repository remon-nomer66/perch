import Testing

@testable import Perch

// Whether the rule editor is offered, and the reason given when it is not. The two must
// agree: the notice says "this device does not support rules" only while such a device
// is actually connected.

private func panel(_ status: DeviceSummary.Status, bose: Bool) -> PanelModel {
  var panel = PanelModel()
  panel.summary.status = status
  panel.summary.modelName = status == .ready ? "Model X" : nil
  panel.isBose = bose
  return panel
}

@Test func aControllableSonyDeviceSupportsRules() {
  #expect(panel(.ready, bose: false).supportsRules)
}

@Test func aConnectedBoseDeviceIsNamedAsUnsupported() {
  let bose = panel(.ready, bose: true)
  #expect(!bose.supportsRules)
  #expect(bose.ruleUnavailableReason == .unsupportedDevice(modelName: "Model X"))
}

/// A Bose device that is only connecting, or has failed, is not a connected device: the
/// editor waits for one like it does with nothing at all, rather than warning that a
/// device nobody can reach "does not support rules".
@Test(arguments: [DeviceSummary.Status.connecting, .unreachable])
func aBoseDeviceThatIsNotConnectedIsNoDevice(status: DeviceSummary.Status) {
  let bose = panel(status, bose: true)
  #expect(!bose.supportsRules)
  #expect(bose.ruleUnavailableReason == .noDevice)
}

@Test func nothingConnectedIsNoDevice() {
  let none = panel(.noDevice, bose: false)
  #expect(!none.supportsRules)
  #expect(none.ruleUnavailableReason == .noDevice)
}
