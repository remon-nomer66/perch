import Testing

@testable import BosePanel

/// The CNC inversion: the wire counts up toward ambient (0 = quietest), while the UI's
/// strength counts up toward cancellation. These are the two transforms the whole panel
/// relies on, so they are pinned here.
struct BoseCNCStateTests {
  @Test("Wire 0 is full strength; wire max is zero strength")
  func endpoints() {
    let quiet = BoseCNCState(range: 0...10, wireValue: 0)
    #expect(quiet.strength == 10)

    let aware = BoseCNCState(range: 0...10, wireValue: 10)
    #expect(aware.strength == 0)
  }

  @Test("The midpoint maps to the mirrored midpoint")
  func midpoint() {
    let cnc = BoseCNCState(range: 0...10, wireValue: 4)
    #expect(cnc.strength == 6)
  }

  @Test("Strength and wire are exact inverses across the range")
  func roundTrip() {
    let range = 0...10
    for wire in range {
      let strength = BoseCNCState.strength(forWire: wire, in: range)
      #expect(BoseCNCState.wireValue(forStrength: strength, in: range) == wire)
    }
  }

  @Test("A wire value outside the range is clamped")
  func clampsWire() {
    #expect(BoseCNCState(range: 0...10, wireValue: 99).wireValue == 10)
    #expect(BoseCNCState(range: 0...10, wireValue: -5).wireValue == 0)
  }

  @Test("A strength outside the range is clamped before inverting")
  func clampsStrength() {
    #expect(BoseCNCState.wireValue(forStrength: 99, in: 0...10) == 0)
    #expect(BoseCNCState.wireValue(forStrength: -5, in: 0...10) == 10)
  }

  @Test("A non-standard range inverts around its own upper bound")
  func nonStandardRange() {
    let cnc = BoseCNCState(range: 0...8, wireValue: 2)
    #expect(cnc.strength == 6)
    #expect(BoseCNCState.wireValue(forStrength: 6, in: 0...8) == 2)
  }
}
