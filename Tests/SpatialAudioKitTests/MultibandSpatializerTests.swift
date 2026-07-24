import Foundation
import Testing

@testable import SpatialAudioKit

@available(macOS 14.4, *)
@Test func lowContentGoesToBothEarsNotTheSpatialSources() {
  // 低域は両耳の直通路（bassLeft/bassRight）へ。空間化する中央・左右には出さない。
  let low: [Float] = [0.8, -0.4]
  let silent: [Float] = [0, 0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: low, lowRight: low, highLeft: silent, highRight: silent,
    lowGain: 1, midGain: 1, width: 1.1
  )
  #expect(mixed.bassLeft == low)
  #expect(mixed.bassRight == low)
  #expect(mixed.center.allSatisfy { $0 == 0 })
  #expect(mixed.sideLeft.allSatisfy { $0 == 0 })
  #expect(mixed.sideRight.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func lowGainBoostsTheBassInBothEars() {
  // 低域ゲインは両耳のベースを持ち上げる（力強さの調整）。
  let low: [Float] = [0.5]
  let silent: [Float] = [0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: low, lowRight: low, highLeft: silent, highRight: silent,
    lowGain: 2, midGain: 1, width: 1
  )
  #expect(abs(mixed.bassLeft[0] - 1.0) < 1e-6)
  #expect(abs(mixed.bassRight[0] - 1.0) < 1e-6)
}

@available(macOS 14.4, *)
@Test func centredHighContentGoesToTheCentreScaledByMidGain() {
  // 中央成分（L==R の中高域）は中央へ。midGain で歌詞を前に出せる。
  let silent: [Float] = [0, 0]
  let high: [Float] = [0.4, 0.4]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: high, highRight: high,
    lowGain: 1, midGain: 1.5, width: 1
  )
  #expect(abs(mixed.center[0] - 0.6) < 1e-6)  // 0.4 * 1.5
  #expect(mixed.sideLeft.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func pannedHighContentIsWidenedIntoTheSides() {
  // 片chの中高域はサイドへ。width で強調、左右は反転。
  let silent: [Float] = [0]
  let highLeft: [Float] = [1.0]
  let highRight: [Float] = [0.0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: highLeft, highRight: highRight,
    lowGain: 1, midGain: 1, width: 2.0
  )
  #expect(abs(mixed.sideLeft[0] - 1.0) < 1e-6)   // (1-0)/2 * 2
  #expect(abs(mixed.sideRight[0] - (-1.0)) < 1e-6)
  #expect(abs(mixed.center[0] - 0.5) < 1e-6)     // mid = (1+0)/2
}

@available(macOS 14.4, *)
@Test func mismatchedBandLengthsUseTheShortest() {
  let mixed = MultibandSpatializer.mix(
    lowLeft: [1, 2, 3], lowRight: [1, 2], highLeft: [0], highRight: [0],
    lowGain: 1, midGain: 1, width: 1
  )
  #expect(mixed.center.count == 1)
}
