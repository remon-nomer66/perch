import Foundation
import Testing

@testable import SpatialAudioKit

@Test func aSuddenRiseIsDetectedAsABeat() {
  var detector = BeatDetector()
  // 低いレベルで安定させてから、急に立ち上げる。
  for _ in 0..<100 { _ = detector.observe(level: 0.05, dt: 0.01) }
  let strength = detector.observe(level: 1.0, dt: 0.01)
  #expect(strength > 0)
}

@Test func steadyLevelsProduceNoBeats() {
  var detector = BeatDetector()
  // ウォームアップ後、一定レベルが続くなら拍は出ない。
  for _ in 0..<200 { _ = detector.observe(level: 0.5, dt: 0.01) }
  var beats = 0
  for _ in 0..<100 where detector.observe(level: 0.5, dt: 0.01) > 0 { beats += 1 }
  #expect(beats == 0)
}

@Test func theRefractoryPeriodSuppressesDoubleTriggers() {
  var detector = BeatDetector(refractory: 0.15)
  for _ in 0..<100 { _ = detector.observe(level: 0.05, dt: 0.01) }
  let first = detector.observe(level: 1.0, dt: 0.01)
  let immediate = detector.observe(level: 1.0, dt: 0.01)  // 10ms 後 → 不応期内
  #expect(first > 0)
  #expect(immediate == 0)
}

@Test func periodicKicksAreEachDetected() {
  var detector = BeatDetector(refractory: 0.15)
  var beats = 0
  // 0.5秒ごと（=120BPM相当）にキックを入れる。
  for step in 0..<500 {
    let time = Double(step) * 0.01
    let isKick = (step % 50) == 0  // 0.5秒ごと
    let level = isKick ? 1.0 : 0.05
    if detector.observe(level: level, dt: 0.01) > 0 { beats += 1 }
    _ = time
  }
  // 10回前後の拍（最初の warmup 込みで概ね妥当な範囲）。
  #expect(beats >= 8 && beats <= 12)
}

@Test func silenceProducesNoBeats() {
  var detector = BeatDetector(minLevel: 0.004)
  var beats = 0
  // 下限未満の微小な揺れだけ。拍にしない。
  for step in 0..<300 {
    let level = (step % 40 == 0) ? 0.002 : 0.0005
    if detector.observe(level: level, dt: 0.01) > 0 { beats += 1 }
  }
  #expect(beats == 0)
}
