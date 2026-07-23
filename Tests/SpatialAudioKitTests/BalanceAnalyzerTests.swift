import Foundation
import Testing

@testable import SpatialAudioKit

@Test func balancedContentKeepsTheBaselineLowGain() {
  // 低音と中央が同程度なら、低音ゲインは基準のまま（余計にいじらない）。
  let target = BalanceAnalyzer.targets(
    lowEnergy: 1, midEnergy: 1, sideEnergy: 0.25,
    baselineLowGain: 1.3, baselineWidth: 1.1
  )
  #expect(abs(target.lowGain - 1.3) < 1e-4)
}

@Test func weakBassIsBoosted() {
  // 低音が中央より弱い曲では低音ゲインが上がる（上限までクランプ）。
  let target = BalanceAnalyzer.targets(
    lowEnergy: 0.0001, midEnergy: 1, sideEnergy: 0.25,
    baselineLowGain: 1.3, baselineWidth: 1.1
  )
  #expect(target.lowGain > 1.3)
  #expect(target.lowGain <= 2.2)
}

@Test func heavyBassIsPulledBack() {
  // 低音過多の曲では低音ゲインが下がる（下限までクランプ）。
  let target = BalanceAnalyzer.targets(
    lowEnergy: 100, midEnergy: 1, sideEnergy: 0.25,
    baselineLowGain: 1.3, baselineWidth: 1.1
  )
  #expect(target.lowGain < 1.3)
  #expect(target.lowGain >= 1.0)
}

@Test func anAlreadyWideMixIsNarrowed() {
  // 既に左右が広い（サイド大）ミックスは幅を控える。
  let target = BalanceAnalyzer.targets(
    lowEnergy: 1, midEnergy: 1, sideEnergy: 4,
    baselineLowGain: 1.3, baselineWidth: 1.1
  )
  #expect(target.width < 1.1)
  #expect(target.width >= 0.8)
}

@Test func anarrowMixIsWidened() {
  // ほぼモノ（サイド僅少）は広げる（上限までクランプ）。
  let target = BalanceAnalyzer.targets(
    lowEnergy: 1, midEnergy: 1, sideEnergy: 0.000001,
    baselineLowGain: 1.3, baselineWidth: 1.1
  )
  #expect(target.width > 1.1)
  #expect(target.width <= 1.8)
}

@Test func theAppliedValuesMoveSlowlyTowardTheTarget() {
  // スルー: 1ブロック観測しただけでは目標へ飛ばず、基準の近くに留まる。
  var analyzer = BalanceAnalyzer(baselineLowGain: 1.3, baselineWidth: 1.1, windowSeconds: 3, slewSeconds: 5)
  // 極端に低音の弱い入力を1ブロック（約10ms）だけ観測。
  analyzer.observe(lowRMS: 0.001, midRMS: 0.5, sideRMS: 0.2, dt: 0.01)
  // 目標は上限側だが、適用値はまだ基準のすぐ近く。
  #expect(analyzer.lowGain > 1.3)
  #expect(analyzer.lowGain < 1.4)
}

@Test func sustainedContentEventuallyReachesTheTargetRegion() {
  // 同じ傾向が続けば、時間をかけて目標域まで寄る。
  var analyzer = BalanceAnalyzer(baselineLowGain: 1.3, baselineWidth: 1.1, windowSeconds: 3, slewSeconds: 5)
  for _ in 0..<3000 {  // 約30秒ぶん（dt=0.01）
    analyzer.observe(lowRMS: 0.001, midRMS: 0.5, sideRMS: 0.2, dt: 0.01)
  }
  #expect(analyzer.lowGain > 2.0)  // 低音が弱いので上限付近まで持ち上がる
}
