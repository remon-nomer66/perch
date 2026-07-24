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

@Test func earbudsReuseUltraConfig() throws {
  let model = try #require(BoseCatalog.model(forProductId: 0x4062))
  #expect(model.codename == "edith")
  #expect(model.config == .qcUltra2)
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
}
