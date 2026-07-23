import Foundation
import Testing

@testable import SpatialAudioKit

@available(macOS 14.4, *)
@Test func lowContentGoesToTheCentreOnly() {
  // 低域だけの音（中高域ゼロ）は中央にモノで集まり、左右のサイドは無音。
  let low: [Float] = [0.8, -0.4]
  let silent: [Float] = [0, 0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: low, lowRight: low, highLeft: silent, highRight: silent, width: 1.4
  )
  #expect(mixed.center == low)  // (L+R)/2 で L==R なら元のまま
  #expect(mixed.left.allSatisfy { $0 == 0 })
  #expect(mixed.right.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func centredHighContentStaysInTheCentre() {
  // 中高域でも中央成分（L==R）は中央へ。左右のサイドには漏れない。
  let silent: [Float] = [0, 0]
  let high: [Float] = [0.5, 0.5]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: high, highRight: high, width: 1.4
  )
  #expect(mixed.center == high)
  #expect(mixed.left.allSatisfy { $0 == 0 })
  #expect(mixed.right.allSatisfy { $0 == 0 })
}

@available(macOS 14.4, *)
@Test func pannedHighContentIsWidenedIntoTheSides() {
  // 片chに振られた中高域はサイドへ。width で強調され、左右は反転する。
  let silent: [Float] = [0]
  let highLeft: [Float] = [1.0]   // 左だけに音
  let highRight: [Float] = [0.0]
  let mixed = MultibandSpatializer.mix(
    lowLeft: silent, lowRight: silent, highLeft: highLeft, highRight: highRight, width: 2.0
  )
  // side = (1-0)/2 * 2.0 = 1.0、中央 = mid = 0.5
  #expect(abs(mixed.center[0] - 0.5) < 1e-6)
  #expect(abs(mixed.left[0] - 1.0) < 1e-6)
  #expect(abs(mixed.right[0] - (-1.0)) < 1e-6)
}

@available(macOS 14.4, *)
@Test func mismatchedBandLengthsUseTheShortest() {
  let mixed = MultibandSpatializer.mix(
    lowLeft: [1, 2, 3], lowRight: [1, 2], highLeft: [0], highRight: [0], width: 1
  )
  #expect(mixed.center.count == 1)
}
