import CoreGraphics
import Foundation
import Testing

@testable import NotchKit

@Test func outOfRangeValuesAreClampedByTheInitializer() {
  let limits = NotchAppearance.limits
  let appearance = NotchAppearance(
    leadingExtension: -50,
    trailingExtension: 9999,
    closedHeightIncrease: -1,
    restingHeight: 999,
    expandedWidth: 10,
    expandedHeight: 100_000,
    closedBottomCornerRadius: -3,
    expandedBottomCornerRadius: 500,
    topCornerRadius: 41
  )

  #expect(appearance.leadingExtension == limits.sideExtension.lowerBound)
  #expect(appearance.trailingExtension == limits.sideExtension.upperBound)
  #expect(appearance.closedHeightIncrease == limits.closedHeightIncrease.lowerBound)
  #expect(appearance.restingHeight == limits.restingHeight.upperBound)
  #expect(appearance.expandedWidth == limits.expandedWidth.lowerBound)
  #expect(appearance.expandedHeight == limits.expandedHeight.upperBound)
  #expect(appearance.closedBottomCornerRadius == limits.cornerRadius.lowerBound)
  #expect(appearance.expandedBottomCornerRadius == limits.cornerRadius.upperBound)
  #expect(appearance.topCornerRadius == limits.cornerRadius.upperBound)
}

@Test func theRestingHeightDefaultsToASlimSliver() {
  // The virtual notch sits on Macs with no cutout of their own; left alone it is a
  // thin sliver, thin enough not to read as a permanent bar.
  #expect(NotchAppearance.default.restingHeight == 10)
  #expect(NotchAppearance.limits.restingHeight == 4...32)
}

@Test func theRestingSliverHugsTheTopOfTheNotchRegion() {
  let notch = CGRect(x: 610, y: 876, width: 220, height: 24)
  let sliver = NotchAppearance.default.restingSliver(in: notch)

  // The default resting height is 10, so the sliver is the top 10pt of the region.
  #expect(sliver == CGRect(x: 610, y: 890, width: 220, height: 10))
}

@Test func decodingClampsTheSameWayTheInitializerDoes() throws {
  // A stored archive is external data: a corrupted or hand-edited UserDefaults value
  // must not smuggle a negative or absurd size past the limits.
  let json = """
    {
      "leadingExtension": -400,
      "trailingExtension": 80,
      "closedHeightIncrease": 900,
      "expandedWidth": 1e9,
      "expandedHeight": -200,
      "closedBottomCornerRadius": 12,
      "expandedBottomCornerRadius": -1,
      "topCornerRadius": 4000
    }
    """
  let decoded = try JSONDecoder().decode(NotchAppearance.self, from: Data(json.utf8))
  let limits = NotchAppearance.limits

  #expect(decoded.leadingExtension == limits.sideExtension.lowerBound)
  #expect(decoded.trailingExtension == 80)
  #expect(decoded.closedHeightIncrease == limits.closedHeightIncrease.upperBound)
  #expect(decoded.expandedWidth == limits.expandedWidth.upperBound)
  #expect(decoded.expandedHeight == limits.expandedHeight.lowerBound)
  #expect(decoded.closedBottomCornerRadius == 12)
  #expect(decoded.expandedBottomCornerRadius == limits.cornerRadius.lowerBound)
  #expect(decoded.topCornerRadius == limits.cornerRadius.upperBound)
}

@Test func aRoundTripPreservesInRangeValues() throws {
  let original = NotchAppearance.default
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(NotchAppearance.self, from: data)

  #expect(decoded == original)
}

@Test func anArchiveMissingAFieldFailsToDecode() {
  // The store then falls back to the defaults as a whole, rather than inventing the
  // missing fields piecemeal.
  let json = """
    {"leadingExtension": 76}
    """

  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(NotchAppearance.self, from: Data(json.utf8))
  }
}

@Test func anArchivePredatingTheRestingHeightStillDecodes() throws {
  // Resting height was added after the first release. An archive saved before it
  // must keep the sizes its owner chose and simply gain the default sliver, rather
  // than being discarded whole and resetting every other slider they had tuned.
  let json = """
    {
      "leadingExtension": 76,
      "trailingExtension": 52,
      "closedHeightIncrease": 0,
      "expandedWidth": 640,
      "expandedHeight": 200,
      "closedBottomCornerRadius": 12,
      "expandedBottomCornerRadius": 22,
      "topCornerRadius": 10
    }
    """
  let decoded = try JSONDecoder().decode(NotchAppearance.self, from: Data(json.utf8))

  #expect(decoded.restingHeight == NotchAppearance.default.restingHeight)
  #expect(decoded.leadingExtension == 76)
  #expect(decoded.expandedWidth == 640)
}
