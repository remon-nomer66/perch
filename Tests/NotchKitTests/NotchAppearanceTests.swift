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
    expandedWidth: 10,
    expandedHeight: 100_000,
    closedBottomCornerRadius: -3,
    expandedBottomCornerRadius: 500,
    topCornerRadius: 41
  )

  #expect(appearance.leadingExtension == limits.sideExtension.lowerBound)
  #expect(appearance.trailingExtension == limits.sideExtension.upperBound)
  #expect(appearance.closedHeightIncrease == limits.closedHeightIncrease.lowerBound)
  #expect(appearance.expandedWidth == limits.expandedWidth.lowerBound)
  #expect(appearance.expandedHeight == limits.expandedHeight.upperBound)
  #expect(appearance.closedBottomCornerRadius == limits.cornerRadius.lowerBound)
  #expect(appearance.expandedBottomCornerRadius == limits.cornerRadius.upperBound)
  #expect(appearance.topCornerRadius == limits.cornerRadius.upperBound)
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
