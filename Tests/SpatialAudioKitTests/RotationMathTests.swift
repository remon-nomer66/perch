import Foundation
import Testing

@testable import SpatialAudioKit

// 回転数学の性質: Euler 往復・合成/差分・角距離・補間。実装の代数ミスは
// 往復（作って戻す）とアイデンティティの検査でほぼ捕まる。

@Test(
  "Euler 往復: 実用域の yaw/pitch/roll が往って戻る",
  arguments: [
    (0.0, 0.0, 0.0),
    (0.4, 0.0, 0.0),
    (-0.7, 0.0, 0.0),
    (0.0, 0.5, 0.0),
    (0.0, -0.8, 0.0),
    (0.0, 0.0, 0.6),
    (0.3, -0.4, 0.2),
    (-1.2, 0.9, -0.5),
    (2.8, 0.3, 0.1),
  ]
)
func eulerRoundTrip(angles: (Double, Double, Double)) {
  let (yaw, pitch, roll) = angles
  let euler = Rotation(yaw: yaw, pitch: pitch, roll: roll).eulerAngles
  #expect(abs(euler.yaw - yaw) < 1e-9)
  #expect(abs(euler.pitch - pitch) < 1e-9)
  #expect(abs(euler.roll - roll) < 1e-9)
}

@Test("中心化: center⁻¹ × 姿勢 は、中心と同じ姿勢で恒等になる")
func centeringCancels() {
  let pose = Rotation(yaw: 0.3, pitch: -0.2, roll: 0.1)
  let centered = pose.inverse * pose
  #expect(centered.angle(to: .identity) < 1e-9)
}

@Test("中心化: yaw だけ回した差分は yaw の差になる")
func centeredYawIsTheDifference() {
  let center = Rotation(yaw: 0.2, pitch: 0, roll: 0)
  let turned = Rotation(yaw: 0.5, pitch: 0, roll: 0)
  let difference = (center.inverse * turned).eulerAngles
  #expect(abs(difference.yaw - 0.3) < 1e-9)
  #expect(abs(difference.pitch) < 1e-9)
  #expect(abs(difference.roll) < 1e-9)
}

@Test("角距離: 恒等からの yaw θ 回転は角距離 θ")
func angleMeasuresRotation() {
  let turned = Rotation(yaw: 0.8, pitch: 0, roll: 0)
  #expect(abs(turned.angle(to: .identity) - 0.8) < 1e-9)
  #expect(abs(Rotation.identity.angle(to: .identity)) < 1e-9)
}

@Test("slerp: 端では両端、中間では角距離が半分")
func slerpEndpointsAndMidpoint() {
  let a = Rotation.identity
  let b = Rotation(yaw: 1.0, pitch: 0, roll: 0)
  #expect(a.slerp(to: b, fraction: 0).angle(to: a) < 1e-9)
  #expect(a.slerp(to: b, fraction: 1).angle(to: b) < 1e-9)
  let mid = a.slerp(to: b, fraction: 0.5)
  #expect(abs(mid.angle(to: a) - 0.5) < 1e-9)
}

@Test("slerp: 反対符号の同値クォータニオンでも近い側を通る（二重被覆）")
func slerpTakesTheShortWay() {
  let a = Rotation(yaw: 0.1, pitch: 0, roll: 0)
  var b = Rotation(yaw: 0.2, pitch: 0, roll: 0)
  // 同じ回転を表す -q に反転しても、補間は 0.1→0.2 の近い側を通ること。
  b = Rotation(quaternion: .init(vector: -b.quaternion.vector))
  let mid = a.slerp(to: b, fraction: 0.5)
  #expect(abs(mid.eulerAngles.yaw - 0.15) < 1e-6)
}

@Test("Vision 変換: 符号定数がそのまま角度に効く")
func visionConversionAppliesSigns() {
  let flipped = VisionPoseConversion(yawSign: -1, pitchSign: 1, rollSign: 1)
  let rotation = flipped.rotation(yaw: 0.4, pitch: 0.1, roll: 0)
  #expect(abs(rotation.eulerAngles.yaw + 0.4) < 1e-9)
  #expect(abs(rotation.eulerAngles.pitch - 0.1) < 1e-9)
}

@Test("listenerOrientation: ラジアンのまま AVAudio 境界の型へ渡る")
func listenerOrientationCarriesRadians() {
  let orientation = Rotation(yaw: 0.3, pitch: -0.1, roll: 0.05).listenerOrientation
  #expect(abs(orientation.yaw - 0.3) < 1e-9)
  #expect(abs(orientation.pitch + 0.1) < 1e-9)
  #expect(abs(orientation.roll - 0.05) < 1e-9)
}
