import Foundation
import Testing

@testable import SpatialAudioKit

@Test func theAttackIsGradualNotAnInstantJump() {
  // 位置を一瞬で跳ばすと HRTF がクリックする。1ブロックでは全量立ち上がらないこと。
  var pulse = BeatPulse()
  pulse.advance(strength: 1.0, dt: 0.0107)
  #expect(pulse.level > 0)
  #expect(pulse.level < 0.7)
}

@Test func thePulseReachesMostOfItsStrengthQuickly() {
  // 遅すぎると拍のパンチが消える。80ms 以内のピークが十分立つこと。
  var pulse = BeatPulse()
  var peak = 0.0
  for step in 0..<8 {
    pulse.advance(strength: step == 0 ? 1.0 : 0, dt: 0.0107)
    peak = max(peak, pulse.level)
  }
  #expect(peak > 0.65)
}

@Test func thePulseDecaysAfterTheBeat() {
  var pulse = BeatPulse()
  pulse.advance(strength: 1.0, dt: 0.0107)
  for _ in 0..<50 { pulse.advance(strength: 0, dt: 0.0107) }  // 約0.5秒後
  #expect(pulse.level < 0.05)
}

@Test func consecutiveStepsAreBounded() {
  // どのブロック間でも変化量が有界（クリックしない滑らかさの保証）。
  var pulse = BeatPulse()
  var previous = 0.0
  for step in 0..<100 {
    let strength = step % 25 == 0 ? 1.0 : 0.0
    pulse.advance(strength: strength, dt: 0.0107)
    #expect(abs(pulse.level - previous) < 0.5)
    previous = pulse.level
  }
}

@Test func aWeakBeatDuringDecayDoesNotDropTheLevel() {
  // 減衰中に弱い拍が来ても、いま高いレベルを下へ引っ張らない。
  var pulse = BeatPulse()
  pulse.advance(strength: 1.0, dt: 0.0107)
  for _ in 0..<3 { pulse.advance(strength: 0, dt: 0.0107) }
  let before = pulse.level
  pulse.advance(strength: 0.1, dt: 0.0107)
  #expect(pulse.level > before - 0.1)
}
