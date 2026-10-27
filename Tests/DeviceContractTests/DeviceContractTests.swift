import Testing

@testable import DeviceContract

/// The thin shared contract is only what the closed bar and menu icon need; these pin
/// the battery invariants and the headline shape.
struct DeviceContractTests {
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

  @Test("A headline carries brand, model, battery, and controllability for the closed bar")
  func headlineShape() {
    let sony = DeviceHeadline(
      brand: .sony,
      modelName: "WH-1000XM6",
      battery: BatteryReading(cells: [
        .init(enclosure: .left, percent: 80),
        .init(enclosure: .right, percent: 75),
      ]),
      isControllable: true
    )
    #expect(sony.brand == .sony)
    #expect(sony.battery.cells.count == 2)
    #expect(sony.isControllable)

    // A disconnected headline shows no content.
    let empty = DeviceHeadline(brand: .bose)
    #expect(empty.modelName == nil)
    #expect(empty.battery.cells.isEmpty)
    #expect(!empty.isControllable)
  }
}
