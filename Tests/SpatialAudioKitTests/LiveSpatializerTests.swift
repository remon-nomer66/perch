import Foundation
import Testing

@testable import SpatialAudioKit

@available(macOS 14.4, *)
@Test func interleavedStereoSplitsIntoLeftAndRight() {
  // [L,R,L,R,...] を左右に正しく分ける。
  let interleaved: [Float] = [1, 2, 3, 4, 5, 6]
  let (left, right) = LiveSpatializer.deinterleave(interleaved, channels: 2)
  #expect(left == [1, 3, 5])
  #expect(right == [2, 4, 6])
}

@available(macOS 14.4, *)
@Test func moreThanTwoChannelsTakesTheFirstTwo() {
  // 5.1ch 等でも、先頭2chを L/R として扱い、フレーム境界を守る。
  let interleaved: [Float] = [1, 2, 9, 3, 4, 9]  // 3ch × 2フレーム
  let (left, right) = LiveSpatializer.deinterleave(interleaved, channels: 3)
  #expect(left == [1, 3])
  #expect(right == [2, 4])
}

@available(macOS 14.4, *)
@Test func monoIsDuplicatedToBothChannels() {
  // モノは左右へ複製する。無音の左右差を作らない。
  let mono: [Float] = [1, 2, 3]
  let (left, right) = LiveSpatializer.deinterleave(mono, channels: 1)
  #expect(left == mono)
  #expect(right == mono)
}

@available(macOS 14.4, *)
@Test func aRaggedTailIsDroppedRatherThanReadingPastTheEnd() {
  // フレームに満たない端数は捨てる（範囲外アクセスを避ける）。
  let interleaved: [Float] = [1, 2, 3]  // 2ch なら1フレーム+端数1
  let (left, right) = LiveSpatializer.deinterleave(interleaved, channels: 2)
  #expect(left == [1])
  #expect(right == [2])
}
