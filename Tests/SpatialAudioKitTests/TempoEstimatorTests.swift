import Foundation
import Testing

@testable import SpatialAudioKit

/// 既知の周期でパルスの立つフラックス包絡を流し込む。
private func feedImpulses(
  period: Double, dt: Double = 0.01, seconds: Double = 10
) -> TempoEstimator {
  var estimator = TempoEstimator()
  var nextImpulse = 0.0
  var time = 0.0
  while time < seconds {
    var flux = 0.005
    if time >= nextImpulse {
      flux = 1.0
      nextImpulse += period
    }
    estimator.observe(flux: flux, dt: dt)
    time += dt
  }
  return estimator
}

@Test func aHalfSecondPulseReads120BPM() {
  let estimator = feedImpulses(period: 0.5)
  #expect(estimator.bpm != nil)
  #expect(abs((estimator.bpm ?? 0) - 120) <= 3)
}

@Test func aPoint4SecondPulseReads150BPM() {
  let estimator = feedImpulses(period: 0.4)
  #expect(abs((estimator.bpm ?? 0) - 150) <= 3)
}

@Test func eighthNotePulsesFoldIntoTheMusicalRange() {
  // 0.25秒間隔（240BPM相当）は範囲外。半分の120BPMとして読む。
  let estimator = feedImpulses(period: 0.25)
  #expect(abs((estimator.bpm ?? 0) - 120) <= 3)
}

@Test func aFlatEnvelopeHasNoTempo() {
  var estimator = TempoEstimator()
  for _ in 0..<1_000 { estimator.observe(flux: 0.02, dt: 0.01) }
  #expect(estimator.bpm == nil)
}

@Test func theTempoClearsAfterTheMusicStops() {
  var estimator = feedImpulses(period: 0.5)
  #expect(estimator.bpm != nil)
  // 8秒の無音で窓からパルスが抜け、テンポ表示も消える。
  for _ in 0..<800 { estimator.observe(flux: 0, dt: 0.01) }
  #expect(estimator.bpm == nil)
}

// MARK: - 実音（合成BGM）との答え合わせ

private let sampleRate = 48_000.0

private func detectorFedWithBGM(bpm: Double, seconds: Double) -> SpectralFluxDetector {
  var generator = BGMGenerator(bpm: bpm, sampleRate: sampleRate)
  let (left, right) = generator.render(frameCount: Int(seconds * sampleRate))
  var mono = [Float](repeating: 0, count: left.count)
  for index in 0..<left.count { mono[index] = (left[index] + right[index]) * 0.5 }
  let detector = SpectralFluxDetector(sampleRate: sampleRate)!
  var position = 0
  while position < mono.count {
    let end = min(position + 512, mono.count)
    _ = detector.observe(mono: Array(mono[position..<end]))
    position = end
  }
  return detector
}

@Test func theDetectorReadsTheBGMTempo() {
  let detector = detectorFedWithBGM(bpm: 120, seconds: 10)
  #expect(detector.estimatedBPM != nil)
  #expect(abs((detector.estimatedBPM ?? 0) - 120) <= 5)
}

@Test func aSlowerBGMReadsItsOwnTempo() {
  let detector = detectorFedWithBGM(bpm: 100, seconds: 10)
  #expect(abs((detector.estimatedBPM ?? 0) - 100) <= 5)
}
