import AVFoundation
import Testing

@testable import SpatialAudioKit

@Test func qualityMapsToTheMatchingHRTFAlgorithm() {
  // 品質段階とレンダリングアルゴリズムの対応を固定する。取り違えると音質が変わる。
  #expect(SpatialRenderingQuality.standard.audioAlgorithm == .HRTF)
  #expect(SpatialRenderingQuality.high.audioAlgorithm == .HRTFHQ)
  #expect(SpatialRenderingQuality.light.audioAlgorithm == .sphericalHead)
}

@Test func frontDirectionMapsToANegativeZPoint() {
  // 正面は -Z。核の軸の約束が境界の Float 変換でも保たれることを確かめる。
  let p = SphericalDirection(azimuth: 0, elevation: 0, distance: 2).audioPoint
  #expect(abs(p.x) < 1e-5)
  #expect(abs(p.y) < 1e-5)
  #expect(abs(p.z - (-2)) < 1e-5)
}

@Test func rightDirectionMapsToAPositiveXPoint() {
  let p = SphericalDirection(azimuth: .pi / 2, elevation: 0, distance: 1).audioPoint
  #expect(abs(p.x - 1) < 1e-5)
  #expect(abs(p.z) < 1e-5)
}

@Test func listenerDegreesMapIntoTheAngularOrientation() {
  // ラジアンで持つ向きが、境界で度に変換されて渡ることを確かめる。
  let o = ListenerOrientation(yaw: .pi / 2, pitch: 0, roll: -.pi / 4).audioOrientation
  #expect(abs(o.yaw - 90) < 1e-3)
  #expect(abs(o.roll - (-45)) < 1e-3)
}
