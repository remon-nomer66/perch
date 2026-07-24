import Foundation
import Testing

@testable import SpatialAudioKit

// 相対距離の約束: 基準からの比率・yaw ゲート・単発外れ値の棄却・顔枠幅フォールバック。

@Test("基準と同じ IPD は比率 1、半分の IPD は比率 2 へ向かう")
func ratioFollowsInverseIPD() {
  var estimator = RelativeDistanceEstimator(referenceIPD: 60, smoothing: 1.0, maxStep: 10)
  #expect(abs(estimator.update(pixelIPD: 60, faceWidth: nil, yaw: 0) - 1.0) < 1e-9)
  let after = estimator.update(pixelIPD: 30, faceWidth: nil, yaw: 0)
  #expect(abs(after - 2.0) < 1e-9)
}

@Test("横を向いている間（|yaw| > ゲート）は更新しない")
func yawGateHoldsTheValue() {
  var estimator = RelativeDistanceEstimator(referenceIPD: 60, smoothing: 1.0, maxStep: 10)
  estimator.update(pixelIPD: 60, faceWidth: nil, yaw: 0)
  // 横向きで IPD が投影短縮しても、距離は動かないこと。
  let held = estimator.update(pixelIPD: 30, faceWidth: nil, yaw: 0.8)
  #expect(abs(held - 1.0) < 1e-9)
}

@Test("単発の外れ値は棄却、同水準が2回続けば本物の移動")
func outlierNeedsConfirmation() {
  var estimator = RelativeDistanceEstimator(referenceIPD: 60, smoothing: 1.0, maxStep: 1.3)
  estimator.update(pixelIPD: 60, faceWidth: nil, yaw: 0)
  // 誤検出の1フレーム: 遠くへ大ジャンプ → 保留され、値は動かない。
  let afterSpike = estimator.update(pixelIPD: 20, faceWidth: nil, yaw: 0)
  #expect(abs(afterSpike - 1.0) < 1e-9)
  // 同水準がもう1回 → 本当に移動したと認めて追従する。
  let confirmed = estimator.update(pixelIPD: 21, faceWidth: nil, yaw: 0)
  #expect(confirmed > 2.0)
}

@Test("瞳が取れなくなったら、学習した顔枠幅で代算する")
func fallsBackToFaceWidth() {
  var estimator = RelativeDistanceEstimator(referenceIPD: 60, smoothing: 1.0, maxStep: 10)
  // 瞳と顔枠の両方が見えている間に係数を学習（幅 200px ↔ 比率 1.0）。
  estimator.update(pixelIPD: 60, faceWidth: 200, yaw: 0)
  // 瞳が取れない遠距離: 幅が半分 → 距離はおよそ倍。
  let far = estimator.update(pixelIPD: nil, faceWidth: 100, yaw: 0)
  #expect(abs(far - 2.0) < 0.1)
}

@Test("学習前に瞳が取れないフレームは値を保つ")
func noFallbackBeforeLearning() {
  var estimator = RelativeDistanceEstimator(referenceIPD: 60, smoothing: 1.0)
  let held = estimator.update(pixelIPD: nil, faceWidth: 100, yaw: 0)
  #expect(abs(held - 1.0) < 1e-9)
}

@Test("比率は許容範囲へクランプされる")
func ratioIsClamped() {
  var estimator = RelativeDistanceEstimator(
    referenceIPD: 60, smoothing: 1.0, maxStep: 100, range: 0.4...5.0
  )
  let extreme = estimator.update(pixelIPD: 1, faceWidth: nil, yaw: 0)
  #expect(extreme <= 5.0)
}
