import Foundation
import Testing

@testable import SpatialAudioKit

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
  abs(a - b) < tolerance
}

@Test func theLeftAndRightSpeakersOpenSymmetricallyFromCentre() {
  // 左は負、右は正の方位角。中央に対して対称に開く。
  let field = StereoField(spread: .pi / 6, distance: 1)
  #expect(isClose(field.left.azimuth, -.pi / 6))
  #expect(isClose(field.right.azimuth, .pi / 6))
  #expect(isClose(field.left.elevation, 0))
  #expect(isClose(field.right.elevation, 0))
}

@Test func bothSpeakersSitAtTheGivenDistance() {
  let field = StereoField(spread: .pi / 6, distance: 2.5)
  #expect(isClose(field.left.distance, 2.5))
  #expect(isClose(field.right.distance, 2.5))
}

@Test func theDefaultSpreadIsThirtyDegrees() {
  // 既定はステレオスピーカーの標準配置に倣った 30°。
  let field = StereoField()
  #expect(isClose(field.spread, .pi / 6))
  #expect(isClose(field.right.azimuth, .pi / 6))
}

@Test func aSpreadWiderThanNinetyDegreesIsClampedToSideways() {
  // 開き角は真横（π/2）まで。それ以上は真横に丸める。もっともらしい既定へは化かさない。
  let tooWide = StereoField(spread: .pi, distance: 1)
  #expect(isClose(tooWide.spread, .pi / 2))
  #expect(isClose(tooWide.right.azimuth, .pi / 2))
}

@Test func aNegativeSpreadCollapsesToTheCentre() {
  // 負の開き角は 0（左右とも正面に重なる）に丸める。
  let collapsed = StereoField(spread: -1, distance: 1)
  #expect(isClose(collapsed.spread, 0))
  #expect(isClose(collapsed.left.azimuth, 0))
  #expect(isClose(collapsed.right.azimuth, 0))
}
