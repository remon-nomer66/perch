import Foundation
import Testing

@testable import SpatialAudioKit

// 観測の約束: 「顔あり / 後ろ向きの人あり / 誰もいない（判定不能）」を区別して運ぶ。
// 既存の4引数の呼び出しは、回転の有無から従来どおりの意味になる。

@Test("従来の作り方: 回転があれば顔あり、無ければ判定不能")
func legacyInitDerivesPresence() {
  let face = HeadPoseSample(time: 0, rotation: .identity, pixelIPD: 60, faceWidth: 200)
  #expect(face.presence == .faceVisible)

  let lost = HeadPoseSample(time: 0, rotation: nil, pixelIPD: nil, faceWidth: nil)
  #expect(lost.presence == .undetermined)
}

@Test("後ろ向きの観測は回転・距離を持たない")
func facingAwayCarriesNoPose() {
  let away = HeadPoseSample.facingAway(time: 1.5)
  #expect(away.time == 1.5)
  #expect(away.rotation == nil)
  #expect(away.pixelIPD == nil)
  #expect(away.faceWidth == nil)
  #expect(away.presence == .facingAway)
}

@Test("回転が取れていれば、指定に関わらず顔あり（矛盾した観測を作らない）")
func rotationImpliesAVisibleFace() {
  let sample = HeadPoseSample(
    time: 0, rotation: .identity, pixelIPD: nil, faceWidth: nil, presence: .facingAway
  )
  #expect(sample.presence == .faceVisible)
}

@Test("顔は見えたが姿勢角が取れない観測は、回転なしの顔あり")
func faceWithoutAngles() {
  let sample = HeadPoseSample(
    time: 0, rotation: nil, pixelIPD: nil, faceWidth: 180, presence: .faceVisible
  )
  #expect(sample.rotation == nil)
  #expect(sample.presence == .faceVisible)
}
