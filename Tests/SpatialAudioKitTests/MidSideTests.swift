import Foundation
import Testing

@testable import SpatialAudioKit

@Test func encodeThenDecodeRestoresTheOriginalStereo() {
  // M/S 往復は元の L/R を厳密に復元する。
  let left: [Float] = [0.5, -0.2, 0.8, -1.0]
  let right: [Float] = [0.1, 0.4, -0.3, 0.6]
  let (mid, side) = MidSide.encode(left: left, right: right)
  let (l2, r2) = MidSide.decode(mid: mid, side: side)
  for index in left.indices {
    #expect(abs(l2[index] - left[index]) < 1e-6)
    #expect(abs(r2[index] - right[index]) < 1e-6)
  }
}

@Test func aCentredSignalHasNoSide() {
  // 完全に中央（L==R）の音は Side が 0。パンされた楽器だけが Side に出る。
  let mono: [Float] = [0.3, -0.5, 0.9]
  let (mid, side) = MidSide.encode(left: mono, right: mono)
  #expect(mid == mono)
  #expect(side.allSatisfy { abs($0) < 1e-6 })
}

@Test func aHardPannedSignalIsHalfMidHalfSide() {
  // 片chだけの音（例: 右に振り切り）は Mid と Side に半分ずつ分かれる。
  let right: [Float] = [1.0, 0.6]
  let silent: [Float] = [0.0, 0.0]
  let (mid, side) = MidSide.encode(left: silent, right: right)
  #expect(abs(mid[0] - 0.5) < 1e-6)
  #expect(abs(side[0] - (-0.5)) < 1e-6)
}
