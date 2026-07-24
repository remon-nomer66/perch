import Foundation
import Testing

@testable import SpatialAudioKit

// One Euro の約束: 静止ジッタは均され、速い動きには食いつく。dt は明示的に渡すので
// テストは決定的。

@Test("一定入力はそのまま通る")
func constantPassesThrough() {
  var filter = OneEuroFilter()
  var value = 0.0
  for _ in 0..<50 {
    value = filter.filter(5.0, dt: 1.0 / 30)
  }
  #expect(abs(value - 5.0) < 1e-6)
}

@Test("小さなジッタは振幅が縮む")
func jitterIsAttenuated() {
  var filter = OneEuroFilter(minCutoff: 1.0, beta: 0)
  // ±0.5 で毎フレーム反転する矩形ジッタ。出力の振れ幅は入力より狭くなる。
  var outputs: [Double] = []
  for index in 0..<100 {
    let noisy = index % 2 == 0 ? 0.5 : -0.5
    outputs.append(filter.filter(noisy, dt: 1.0 / 30))
  }
  let tail = outputs.suffix(20)
  let amplitude = (tail.max()! - tail.min()!) / 2
  #expect(amplitude < 0.25, "ジッタが半分以下に均されること (実測 \(amplitude))")
}

@Test("beta が大きいほど速い動きへの遅れが小さい")
func betaReducesLagDuringFastMotion() {
  var slack = OneEuroFilter(minCutoff: 0.5, beta: 0)
  var eager = OneEuroFilter(minCutoff: 0.5, beta: 2.0)
  var slackValue = 0.0
  var eagerValue = 0.0
  // 1秒で 0→3 のランプ（速い動き）。
  for step in 1...30 {
    let target = Double(step) / 10
    slackValue = slack.filter(target, dt: 1.0 / 30)
    eagerValue = eager.filter(target, dt: 1.0 / 30)
  }
  #expect(abs(eagerValue - 3.0) < abs(slackValue - 3.0), "速度適応が遅れを縮めること")
}

@Test("回転版: 一定の回転入力に収束する")
func rotationConvergesToConstant() {
  var filter = RotationOneEuroFilter()
  let target = Rotation(yaw: 0.5, pitch: -0.2, roll: 0.1)
  var output = Rotation.identity
  for _ in 0..<60 {
    output = filter.filter(target, dt: 1.0 / 30)
  }
  #expect(output.angle(to: target) < 0.01)
}

@Test("回転版: ジッタする向きは平均近くに落ち着く")
func rotationJitterIsSmoothed() {
  var filter = RotationOneEuroFilter(minCutoff: 1.0, beta: 0)
  var output = Rotation.identity
  for index in 0..<100 {
    let jitter = index % 2 == 0 ? 0.05 : -0.05
    output = filter.filter(Rotation(yaw: 0.3 + jitter, pitch: 0, roll: 0), dt: 1.0 / 30)
  }
  // 出力は中心 0.3 の近く、ジッタ振幅 0.05 の半分以内。
  #expect(abs(output.eulerAngles.yaw - 0.3) < 0.025)
}
