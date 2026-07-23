import CoreGraphics
import Testing

@testable import NotchKit

// MARK: - Splitting

@Test func splitDividesAtTheFirstHyphen() {
  let parts = HeaderTitleMorph.split("AB-1000XZ9")
  #expect(parts.series == "AB-")
  #expect(parts.model == "1000XZ9")
}

@Test func splitKeepsHyphenlessNamesWhole() {
  let parts = HeaderTitleMorph.split("Buds Pro")
  #expect(parts.series == "")
  #expect(parts.model == "Buds Pro")
}

@Test func splitKeepsATrailingHyphenWhole() {
  let parts = HeaderTitleMorph.split("ABC-")
  #expect(parts.series == "")
  #expect(parts.model == "ABC-")
}

// MARK: - Placement

private let series = CGSize(width: 30, height: 10)
private let model = CGSize(width: 50, height: 12)

@Test func closedPlacementStacksTheSeriesOverTheModel() {
  let p = HeaderTitleMorph.placement(series: series, model: model, progress: 0)
  #expect(p.series == CGPoint(x: 0, y: 0))
  // The lines pull together by the 1pt overlap the stacked label always used.
  #expect(p.model == CGPoint(x: 0, y: 9))
  #expect(p.size == CGSize(width: 50, height: 21))
}

@Test func openPlacementLaysTheTitleOnOneLine() {
  let p = HeaderTitleMorph.placement(series: series, model: model, progress: 1)
  // Each half is centred on the taller one's line.
  #expect(p.series == CGPoint(x: 0, y: 1))
  #expect(p.model == CGPoint(x: 30, y: 0))
  #expect(p.size == CGSize(width: 80, height: 12))
}

@Test func halfwayPlacementSitsBetweenTheEndpoints() {
  let p = HeaderTitleMorph.placement(series: series, model: model, progress: 0.5)
  #expect(p.series == CGPoint(x: 0, y: 0.5))
  #expect(p.model == CGPoint(x: 15, y: 4.5))
  #expect(p.size == CGSize(width: 65, height: 16.5))
}

@Test func overshootExtrapolatesPastTheOpenPlacement() {
  // The opening spring overshoots its target; the halves must keep moving in the same
  // direction instead of clamping at the endpoint and stalling mid-bounce.
  let p = HeaderTitleMorph.placement(series: series, model: model, progress: 1.2)
  #expect(abs(p.model.x - 36) < 0.0001)
  #expect(abs(p.model.y - -1.8) < 0.0001)
  #expect(abs(p.size.width - 86) < 0.0001)
  #expect(abs(p.size.height - 10.2) < 0.0001)
}
