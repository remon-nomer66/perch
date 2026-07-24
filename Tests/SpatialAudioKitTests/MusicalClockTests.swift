import Foundation
import Testing

@testable import SpatialAudioKit

@Test func beatsAdvanceAtTheGivenTempo() {
  var clock = MusicalClock()
  // 120BPM で1秒 → 2拍。
  for _ in 0..<100 { clock.advance(dt: 0.01, bpm: 120) }
  #expect(abs(clock.beats - 2.0) < 0.01)
}

@Test func theSyncWeightRampsUpWhileTempoIsKnown() {
  var clock = MusicalClock()
  #expect(clock.syncWeight == 0)
  for _ in 0..<600 { clock.advance(dt: 0.01, bpm: 120) }  // 6秒
  #expect(clock.syncWeight > 0.9)
}

@Test func losingTheTempoFadesTheWeightBackDown() {
  var clock = MusicalClock()
  for _ in 0..<600 { clock.advance(dt: 0.01, bpm: 120) }
  for _ in 0..<800 { clock.advance(dt: 0.01, bpm: nil) }  // 8秒テンポ不明
  #expect(clock.syncWeight < 0.1)
}

@Test func beatsKeepAdvancingAtTheLastKnownTempo() {
  // テンポを見失った直後に拍が止まると位相が跳ぶ。最後のBPMで刻み続ける。
  var clock = MusicalClock()
  for _ in 0..<100 { clock.advance(dt: 0.01, bpm: 120) }
  for _ in 0..<100 { clock.advance(dt: 0.01, bpm: nil) }
  #expect(abs(clock.beats - 4.0) < 0.01)
}

@Test func withNoTempoEverTheClockStaysStill() {
  var clock = MusicalClock()
  for _ in 0..<100 { clock.advance(dt: 0.01, bpm: nil) }
  #expect(clock.beats == 0)
  #expect(clock.syncWeight == 0)
}
