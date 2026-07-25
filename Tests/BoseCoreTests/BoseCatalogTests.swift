import Foundation
import Testing

@testable import BoseCore

@Test func catalogResolvesUltraHeadphones() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4082))
  #expect(model.codename == "wolverine")
  #expect(model.config.rfcommChannel == 2)
  #expect(model.config.initializeAddress == nil)
  #expect(model.config.batteryLayout == .componentGroups)
  #expect(model.config.supports(.equalizer))
  #expect(model.config.supports(.noiseControlLiveWrite))
  #expect(model.config.supports(.adaptiveNoiseReduction) == false)
  #expect(model.config.supportsModeBlock)
}

@Test func ultraConfigHasNoInitializeFrame() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4082))
  #expect(try model.config.makeInitializeFrame() == nil)
}

@Test func earbudsUseUltraEarbudsConfig() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4062))
  #expect(model.codename == "edith")
  // The earbuds share the Ultra 2 dialect but withhold wind reduction, which they do
  // not carry — so they take the earbuds variant, not the headphones' config.
  #expect(model.config == .qcUltra2Earbuds)
  #expect(model.config.supportsWindReduction == false)
  #expect(BoseDeviceConfig.qcUltra2.supportsWindReduction == true)
}

@Test func catalogResolvesQC35() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4020))
  #expect(model.codename == "baywolf")
  #expect(model.config.rfcommChannel == 8)
  #expect(model.config.batteryLayout == .singleByte)
  #expect(model.config.supports(.adaptiveNoiseReduction))
  #expect(model.config.supports(.equalizer) == false)
  #expect(model.config.supportsModeBlock == false)
  // QC35 needs the [0.1] connect ping; the built frame is 00 01 01 00.
  let initFrame = try #require(try model.config.makeInitializeFrame())
  #expect(initFrame.encoded() == Data([0x00, 0x01, 0x01, 0x00]))
}

@Test func qc35FamilySharesConfig() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x400C))
  #expect(model.codename == "wolfcastle")
  #expect(model.config == .qc35)
}

@Test func unknownProductIdFallsBackWithoutFailing() {
  #expect(BoseCatalog.model(forProductId: 0x9999) == nil)
  #expect(BoseCatalog.isSupported(productId: 0x9999) == false)
  #expect(BoseCatalog.config(forProductId: 0x9999) == BoseCatalog.fallbackConfig)
  #expect(BoseCatalog.fallbackConfig == .qcUltra2)
}

@Test func vendorIdIsBose() {
  #expect(BoseCatalog.vendorId == 0x05A7)
  #expect(BoseCatalog.bluetoothSIGVendorId == 0x009E)
}

/// A Device ID record says which numbering its vendor id is in. Both are real Bose ids in
/// their own namespace, and a QC Ultra Earbuds announces the Bluetooth SIG one — matching
/// only the USB id refused a genuine Bose device and left the catalog unwired.
@Test func boseVendorIsRecognisedInEitherNumbering() {
  // source 1 = Bluetooth SIG, 2 = USB Implementer's Forum.
  #expect(BoseCatalog.isBoseVendor(0x009E, source: 1))
  #expect(BoseCatalog.isBoseVendor(0x05A7, source: 2))
  // Right id, wrong namespace: 0x05A7 is not Bose in the SIG list.
  #expect(!BoseCatalog.isBoseVendor(0x05A7, source: 1))
  #expect(!BoseCatalog.isBoseVendor(0x009E, source: 2))
  // No source declared: either number is still Bose, anything else is not.
  #expect(BoseCatalog.isBoseVendor(0x009E, source: nil))
  #expect(BoseCatalog.isBoseVendor(0x05A7, source: nil))
  #expect(!BoseCatalog.isBoseVendor(0x004C, source: nil))  // Apple
  #expect(!BoseCatalog.isBoseVendor(0x004C, source: 1))
}

/// Read off the hardware this was developed against, not the reference list: the unit
/// announcing 0x4072 completed a full BMAP session in the Ultra 2 dialect.
@Test func catalogResolvesTheHardwareVerifiedEarbuds() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4072))
  #expect(model.config == .qcUltra2Earbuds)
  // The point of identifying it: earbuds must not be offered wind reduction.
  #expect(model.config.supportsWindReduction == false)
  #expect(BoseCatalog.isSupported(productId: 0x4072))
}
