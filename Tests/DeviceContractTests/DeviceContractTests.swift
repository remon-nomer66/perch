import Testing

@testable import DeviceContract

/// The contract's foundation is pure value logic; these pin the derived behaviour the UI
/// and adapters rely on.
struct DeviceContractTests {
  @Test("Readable phases are ready, unverified, and suspended")
  func readablePhases() {
    #expect(ConnectionPhase.ready.isReadable)
    #expect(ConnectionPhase.unverified(.unknownModel).isReadable)
    #expect(ConnectionPhase.suspended(resume: .ready).isReadable)
    #expect(!ConnectionPhase.noDevice.isReadable)
    #expect(!ConnectionPhase.connecting.isReadable)
    #expect(!ConnectionPhase.reading.isReadable)
    #expect(!ConnectionPhase.contended.isReadable)
    #expect(!ConnectionPhase.unreachable(canRetry: true).isReadable)
  }

  @Test("Retry is meaningful only from contended and spent-budget unreachable")
  func retryablePhases() {
    #expect(ConnectionPhase.contended.canRetry)
    #expect(ConnectionPhase.unreachable(canRetry: true).canRetry)
    #expect(!ConnectionPhase.unreachable(canRetry: false).canRetry)
    #expect(!ConnectionPhase.ready.canRetry)
    #expect(!ConnectionPhase.suspended(resume: .ready).canRetry)
  }

  @Test("Write availability gates writes independently of trust")
  func writeAvailability() {
    #expect(WriteAvailability.writable.canWriteNow)
    #expect(!WriteAvailability.readOnly.canWriteNow)
    #expect(!WriteAvailability.suspended.canWriteNow)
    #expect(!WriteAvailability.unavailable.canWriteNow)
  }

  @Test("Feature write needs both device-wide and per-feature permission")
  func perFeatureWriteGate() {
    let caps = DeviceCapabilities(
      trust: .unverified(.unknownModel),
      writeAvailability: .writable,
      features: [
        .noiseControl: .init(read: .fresh, write: .writable),
        .sidetone: .init(read: .fresh, write: .disabled),   // present but control-disabled
      ]
    )
    #expect(caps.declares(.noiseControl))
    #expect(caps.declares(.sidetone))
    #expect(!caps.declares(.equalizer))
    #expect(caps.canWrite(.noiseControl))
    #expect(!caps.canWrite(.sidetone))          // disabled feature refuses the write
    #expect(!caps.canWrite(.equalizer))         // undeclared
  }

  @Test("Read-only device blocks every feature write even when the feature is writable")
  func deviceWideReadOnlyGate() {
    let caps = DeviceCapabilities(
      trust: .unverified(.verificationFailed),
      writeAvailability: .readOnly,
      features: [.noiseControl: .init(read: .fresh, write: .writable)]
    )
    #expect(caps.declares(.noiseControl))       // still declared and readable
    #expect(!caps.canWrite(.noiseControl))      // but the device is gated read-only
  }

  @Test("Battery validates percent, dedupes enclosures, and preserves order")
  func batteryInvariants() {
    #expect(BatteryReading.unknown.cells.isEmpty)
    let b = BatteryReading(cells: [
      .init(enclosure: .left, percent: 80, charge: .notCharging),
      .init(enclosure: .right, percent: 150),                     // out of range → nil
      .init(enclosure: .caseEnclosure, percent: 50, charge: .charging),
      .init(enclosure: .left, percent: 10),                       // duplicate → dropped
    ])
    #expect(b.cells.count == 3)
    #expect(b.cells[0].enclosure == .left)
    #expect(b.cells[0].percent == 80)                             // first write wins
    #expect(b.cells[1].percent == nil)                            // 150 rejected
    #expect(b.cells[2].charge == .charging)
  }

  @Test("Charge state distinguishes not-charging from unknown from charged")
  func chargeStates() {
    #expect(ChargeState.notCharging != ChargeState.unknown)
    #expect(ChargeState.charged != ChargeState.charging)
  }

  @Test("Descriptor holds model only; codec is absent by design")
  func descriptorShape() {
    let d = DeviceDescriptor(brand: .bose, modelName: "QC Ultra 2")
    #expect(d.brand == .bose)
    #expect(d.firmwareVersion == nil)
  }
}
