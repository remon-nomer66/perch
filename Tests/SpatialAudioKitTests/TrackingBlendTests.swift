import Foundation
import Testing

@testable import SpatialAudioKit

// ロスト受け皿の約束: 切れたらゆっくり中立へ、戻ったらゆっくり追従へ。
// 距離も同じ重みで 1.0（中立）へ — 見失いを「離席」と誤解して音量を下げない。

@Test("追跡が続けば出力は追跡値に達する")
func trackingReachesTheTarget() {
  var blend = TrackingBlend(fadeIn: 0.4, fadeOut: 2.0)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  var output = Rotation.identity
  for _ in 0..<30 {
    (output, _) = blend.advance(tracked: target, distanceRatio: 1.8, dt: 1.0 / 15)
  }
  #expect(output.angle(to: target) < 1e-6)
}

@Test("ロストで fadeOut 経過後は中立（正面・距離1）へ戻る")
func lostFadesToNeutral() {
  var blend = TrackingBlend(fadeIn: 0.1, fadeOut: 1.0)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  for _ in 0..<15 {
    _ = blend.advance(tracked: target, distanceRatio: 2.0, dt: 1.0 / 15)
  }
  var output = (rotation: Rotation.identity, distanceRatio: 0.0)
  for _ in 0..<20 {
    output = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  #expect(output.rotation.angle(to: .identity) < 1e-6)
  #expect(abs(output.distanceRatio - 1.0) < 1e-6)
  #expect(blend.isNeutral)
}

@Test("ロスト直後は一気に飛ばず、途中の値を通る")
func lostFadesGradually() {
  var blend = TrackingBlend(fadeIn: 0.1, fadeOut: 2.0)
  let target = Rotation(yaw: 0.6, pitch: 0, roll: 0)
  for _ in 0..<15 {
    _ = blend.advance(tracked: target, distanceRatio: nil, dt: 1.0 / 15)
  }
  // ロスト 0.5 秒後: まだ半分以上残っているはず（fadeOut 2 秒）。
  var output = Rotation.identity
  for _ in 0..<8 {
    (output, _) = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  let yaw = output.eulerAngles.yaw
  #expect(yaw > 0.3 && yaw < 0.6, "段階的に戻ること (実測 \(yaw))")
}

@Test("復帰したら fadeIn でゆっくり追従に戻る")
func reacquireRampsBackIn() {
  var blend = TrackingBlend(fadeIn: 1.0, fadeOut: 0.1)
  let target = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  // 一度完全に中立へ。
  for _ in 0..<30 {
    _ = blend.advance(tracked: nil, distanceRatio: nil, dt: 1.0 / 15)
  }
  // 復帰 1 フレーム目: まだ目標には遠い。
  let (first, _) = blend.advance(tracked: target, distanceRatio: nil, dt: 1.0 / 15)
  #expect(first.angle(to: target) > 0.3)
}
