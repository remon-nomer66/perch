import Testing

@testable import DeviceContract

/// The contract's foundation is pure value logic; these pin the derived behaviour that
/// the UI and the brand adapters will rely on.
struct DeviceContractTests {
  @Test("Controllable statuses are exactly ready and unverified")
  func controllableStatuses() {
    #expect(ConnectionStatus.ready.isControllable)
    #expect(ConnectionStatus.unverified(caveat: "x").isControllable)
    #expect(!ConnectionStatus.readOnly(caveat: "x").isControllable)
    #expect(!ConnectionStatus.noDevice.isControllable)
    #expect(!ConnectionStatus.connecting.isControllable)
    #expect(!ConnectionStatus.reading.isControllable)
    #expect(!ConnectionStatus.contended.isControllable)
    #expect(!ConnectionStatus.unreachable.isControllable)
  }

  @Test("Write trust gates writes; only read-only refuses")
  func writeTrustGate() {
    #expect(WriteTrust.trusted.allowsWrites)
    #expect(WriteTrust.experimental.allowsWrites)
    #expect(!WriteTrust.readOnly.allowsWrites)
  }

  @Test("Capability declaration is membership, independent of write trust")
  func capabilityDeclaration() {
    let caps = DeviceCapabilities(features: [.noiseControl, .sidetone], writeTrust: .readOnly)
    #expect(caps.declares(.noiseControl))
    #expect(caps.declares(.sidetone))
    #expect(!caps.declares(.equalizer))
    // A feature can be declared while writes are gated off — the two are separate.
    #expect(!caps.writeTrust.allowsWrites)
  }

  @Test("Battery carries components independently; unknown is empty")
  func batteryComponents() {
    #expect(BatteryReading.unknown.cells.isEmpty)
    let earbuds = BatteryReading(cells: [
      .init(component: .left, percent: 80),
      .init(component: .right, percent: 75),
      .init(component: .caseEnclosure, percent: 50, isCharging: true),
    ])
    #expect(earbuds.cells.count == 3)
    #expect(earbuds.cells[2].isCharging == true)
    #expect(earbuds.cells[0].percent == 80)
  }

  @Test("Identity defaults leave everything but brand unread")
  func identityDefaults() {
    let id = DeviceIdentity(brand: .bose)
    #expect(id.brand == .bose)
    #expect(id.modelName == nil)
    #expect(id.firmwareVersion == nil)
    #expect(id.codec == nil)
  }
}
