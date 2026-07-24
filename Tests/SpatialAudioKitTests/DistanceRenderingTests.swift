import Foundation
import Testing

@testable import SpatialAudioKit

// 距離比→音の距離感の写像の約束: 較正距離(1.0)では何もせず、遠いほど後退し暗くなる。

@Test("比率1は中立: 後退なし・ローパスは実質バイパス")
func neutralDoesNothing() {
  #expect(DistanceRendering.listenerOffset(ratio: 1.0) == 0)
  #expect(DistanceRendering.lowpassCutoff(ratio: 1.0) >= DistanceRendering.bypassCutoff)
}

@Test("遠いほど後退が増え、カットオフは単調に下がる")
func fartherIsDarkerAndFarther() {
  #expect(DistanceRendering.listenerOffset(ratio: 2.0) > DistanceRendering.listenerOffset(ratio: 1.5))
  #expect(DistanceRendering.lowpassCutoff(ratio: 2.0) < DistanceRendering.lowpassCutoff(ratio: 1.5))
  #expect(DistanceRendering.lowpassCutoff(ratio: 3.0) < DistanceRendering.lowpassCutoff(ratio: 2.0))
}

@Test("極端な比率はクランプ: 後退・カットオフとも底がある")
func extremesAreClamped() {
  #expect(DistanceRendering.listenerOffset(ratio: 100) == DistanceRendering.listenerOffset(ratio: 3.5))
  #expect(DistanceRendering.lowpassCutoff(ratio: 100) >= 2_000)
  // 近づく側もクランプ（前へ出過ぎない）。
  #expect(DistanceRendering.listenerOffset(ratio: 0.01) == DistanceRendering.listenerOffset(ratio: 0.5))
}

@Test("一次ローパス: 直流はそのまま、交番（高域）は削れる")
func lowpassFiltersHighNotDC() {
  var direct = OnePoleLowpass()
  let dc = [Float](repeating: 0.8, count: 512)
  let dcOut = direct.process(dc, cutoff: 4_000, sampleRate: 48_000)
  #expect(abs(dcOut[dcOut.count - 1] - 0.8) < 0.01)

  var alternating = OnePoleLowpass()
  let nyquistish = (0..<512).map { Float($0 % 2 == 0 ? 0.8 : -0.8) }
  let highOut = alternating.process(nyquistish, cutoff: 4_000, sampleRate: 48_000)
  let amplitude = highOut.suffix(64).map { abs($0) }.max() ?? 1
  #expect(amplitude < 0.4, "ナイキスト近傍の交番が半分以下に削れること (実測 \(amplitude))")
}

@Test("バイパス域のカットオフでは波形が変わらない")
func bypassPassesThrough() {
  var filter = OnePoleLowpass()
  let samples: [Float] = [0.1, -0.5, 0.9, 0.3]
  let output = filter.process(samples, cutoff: DistanceRendering.bypassCutoff, sampleRate: 48_000)
  #expect(output == samples)
}
