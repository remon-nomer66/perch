import Foundation
import Testing

@testable import SpatialAudioKit

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
  abs(a - b) < tolerance
}

@Test func straightAheadSitsOnTheNegativeZAxis() {
  // 正面（azimuth 0, elevation 0）はリスナーの真ん前。右手系で正面は -Z。
  let front = SphericalDirection(azimuth: 0, elevation: 0, distance: 2)
  let p = front.cartesian
  #expect(isClose(p.x, 0))
  #expect(isClose(p.y, 0))
  #expect(isClose(p.z, -2))
}

@Test func aQuarterTurnRightPutsTheSourceOnThePositiveXAxis() {
  // 右90°（azimuth π/2）は真右。右は +X、正面成分は消える。
  let right = SphericalDirection(azimuth: .pi / 2, elevation: 0, distance: 1)
  let p = right.cartesian
  #expect(isClose(p.x, 1))
  #expect(isClose(p.y, 0))
  #expect(isClose(p.z, 0))
}

@Test func lookingUpMovesTheSourceOntoThePositiveYAxis() {
  // 真上（elevation π/2）は +Y。水平成分は消える。
  let up = SphericalDirection(azimuth: 0, elevation: .pi / 2, distance: 3)
  let p = up.cartesian
  #expect(isClose(p.x, 0))
  #expect(isClose(p.y, 3))
  #expect(isClose(p.z, 0))
}

@Test func distanceScalesTheVectorLength() {
  // 距離はベクトルの長さそのもの。方向を変えずに大きさだけ効く。
  let d = SphericalDirection(azimuth: .pi / 3, elevation: .pi / 5, distance: 4)
  let p = d.cartesian
  let length = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
  #expect(isClose(length, 4))
}

@Test func negativeDistanceIsClampedToZero() {
  // 負の距離は物理的にありえない。0 に丸め、原点に置く。
  let behind = SphericalDirection(azimuth: 1, elevation: 0.5, distance: -5)
  #expect(behind.distance == 0)
  let p = behind.cartesian
  #expect(isClose(p.x, 0))
  #expect(isClose(p.y, 0))
  #expect(isClose(p.z, 0))
}
