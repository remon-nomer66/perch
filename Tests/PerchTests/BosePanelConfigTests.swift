import BoseCore
import Testing

@testable import Perch

// The config the Bose panel draws from. Model names here are synthetic.

private let cataloguedEarbuds: UInt16 = 0x4072
private let cataloguedHeadphones: UInt16 = 0x4082
private let uncatalogued: UInt16 = 0xFFFF

/// A catalogued id settles it: one config drives the wire and the panel, whatever the
/// device calls itself — including a renamed set of headphones whose name says "buds".
@Test func aCataloguedIdIgnoresTheName() {
  let earbuds = BoseCatalog.config(forProductId: cataloguedEarbuds)
  #expect(
    BoseDeviceController.panelConfig(
      wire: earbuds, productId: cataloguedEarbuds, modelName: "Model X Headphones"
    ) == earbuds
  )

  let headphones = BoseCatalog.config(forProductId: cataloguedHeadphones)
  let renamed = BoseDeviceController.panelConfig(
    wire: headphones, productId: cataloguedHeadphones, modelName: "My Buds"
  )
  #expect(renamed == headphones)
  #expect(renamed.supportsWindReduction)
}

/// No id to go on, and the device calls itself earbuds: the provisional Ultra 2 profile
/// would offer wind reduction they do not have, so the panel withholds it.
@Test(arguments: [nil, uncatalogued] as [UInt16?])
func unknownEarbudsWithholdWindReduction(productId: UInt16?) {
  for name in ["Model X Earbuds", "model x buds"] {
    let panel = BoseDeviceController.panelConfig(
      wire: BoseCatalog.fallbackConfig, productId: productId, modelName: name
    )
    #expect(!panel.supportsWindReduction)
  }
}

/// Anything else unknown keeps the provisional profile as it is.
@Test(arguments: [nil, uncatalogued] as [UInt16?])
func unknownHeadphonesKeepTheProvisionalProfile(productId: UInt16?) {
  for name in ["Model X Headphones", nil] as [String?] {
    let panel = BoseDeviceController.panelConfig(
      wire: BoseCatalog.fallbackConfig, productId: productId, modelName: name
    )
    #expect(panel == BoseCatalog.fallbackConfig)
  }
}

/// The name only ever takes a display axis away; the wire dialect stays the one the
/// session was started with.
@Test func theNameNeverChangesTheWireDialect() {
  let panel = BoseDeviceController.panelConfig(
    wire: BoseCatalog.fallbackConfig, productId: nil, modelName: "Model X Earbuds"
  )
  let wire = BoseCatalog.fallbackConfig
  #expect(panel.rfcommChannel == wire.rfcommChannel)
  #expect(panel.initializeAddress == wire.initializeAddress)
  #expect(panel.features == wire.features)
  #expect(panel.batteryLayout == wire.batteryLayout)
  #expect(panel.modeSlots == wire.modeSlots)
}

// MARK: - Through the controller

/// An uncatalogued device that calls itself earbuds connects with no wind-reduction
/// control on its panel, though the live config it reads back carries the wind byte.
@MainActor
@Test func unlistedEarbudsConnectWithoutWindReduction() async {
  let controller = await connectedController(named: "Model X Earbuds")
  #expect(controller.panelModel != nil)
  #expect(controller.panelModel?.state.windReduction == nil)
}

/// The same device under a headphones name keeps it — which is also what shows the
/// scripted mode config does reach the panel.
@MainActor
@Test func unlistedHeadphonesConnectWithWindReduction() async {
  let controller = await connectedController(named: "Model X Headphones")
  #expect(controller.panelModel?.state.windReduction == true)
}

@MainActor
private func connectedController(named name: String) async -> BoseDeviceController {
  let control = "00-11-22-33-44-56"
  let audio = ScriptedAudioOutput(bluetooth: "00-11-22-33-44-55")
  let devices = ScriptedBmapDevices([control: .readsModes(named: name)])
  let controller = BoseDeviceController(audio: audio, devices: devices)
  await controller.tick()
  return controller
}
