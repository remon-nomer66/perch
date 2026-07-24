import Foundation
import Testing

@testable import SpatialAudioKit

/// 定常状態（過渡応答を除いた後半）の実効値。
private func tailRMS(_ signal: [Float], skip: Int) -> Double {
  let tail = signal.dropFirst(skip)
  guard !tail.isEmpty else { return 0 }
  let sum = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
  return (sum / Double(tail.count)).squareRoot()
}

private let sampleRate = 48_000.0

@Test func lowpassPassesLowFrequenciesAndBlocksHigh() {
  let low = ToneGenerator.sine(frequency: 100, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)
  let high = ToneGenerator.sine(frequency: 8_000, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)

  var filterLow = Biquad.lowpass(cutoff: 500, sampleRate: sampleRate)
  var filterHigh = Biquad.lowpass(cutoff: 500, sampleRate: sampleRate)
  let passed = filterLow.process(low)
  let blocked = filterHigh.process(high)

  // 通過帯域はほぼ素通し（正弦振幅1のRMS≒0.707）、遮断帯域は大きく減衰。
  #expect(tailRMS(passed, skip: 4_800) > 0.6)
  #expect(tailRMS(blocked, skip: 4_800) < 0.1)
}

@Test func highpassPassesHighFrequenciesAndBlocksLow() {
  let low = ToneGenerator.sine(frequency: 100, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)
  let high = ToneGenerator.sine(frequency: 8_000, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)

  var filterLow = Biquad.highpass(cutoff: 500, sampleRate: sampleRate)
  var filterHigh = Biquad.highpass(cutoff: 500, sampleRate: sampleRate)
  let blocked = filterLow.process(low)
  let passed = filterHigh.process(high)

  #expect(tailRMS(passed, skip: 4_800) > 0.6)
  #expect(tailRMS(blocked, skip: 4_800) < 0.1)
}

@Test func resetClearsFilterState() {
  var filter = Biquad.lowpass(cutoff: 500, sampleRate: sampleRate)
  _ = filter.process([Float](repeating: 1, count: 100))
  filter.reset()
  // リセット後、最初の出力は b0 * 入力のみ（過去状態ゼロ）になる。
  let first = filter.process(1)
  #expect(abs(first - filter.b0) < 1e-6)
}
