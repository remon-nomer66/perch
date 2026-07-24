import Foundation
import Testing

@testable import SpatialAudioKit

private func tailRMS(_ signal: [Float], skip: Int) -> Double {
  let tail = signal.dropFirst(skip)
  guard !tail.isEmpty else { return 0 }
  let sum = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
  return (sum / Double(tail.count)).squareRoot()
}

private let sampleRate = 48_000.0

@Test func lowContentGoesToTheLowBand() {
  var crossover = Crossover(cutoff: 300, sampleRate: sampleRate)
  let bass = ToneGenerator.sine(frequency: 60, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)
  let (low, high) = crossover.split(bass)
  #expect(tailRMS(low, skip: 4_800) > 0.6)
  #expect(tailRMS(high, skip: 4_800) < 0.15)
}

@Test func highContentGoesToTheHighBand() {
  var crossover = Crossover(cutoff: 300, sampleRate: sampleRate)
  let treble = ToneGenerator.sine(frequency: 6_000, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1)
  let (low, high) = crossover.split(treble)
  #expect(tailRMS(high, skip: 4_800) > 0.6)
  #expect(tailRMS(low, skip: 4_800) < 0.15)
}

@Test func theSplitPreservesBlockLength() {
  var crossover = Crossover(cutoff: 300, sampleRate: sampleRate)
  let (low, high) = crossover.split([Float](repeating: 0.2, count: 512))
  #expect(low.count == 512)
  #expect(high.count == 512)
}

@Test func theBandsSumFlatAtTheCrossoverFrequency() {
  // 分けた帯域は耳で再合成される。バターワース LP+HP の同相和はカットオフで厳密に
  // ゼロになり、250Hz 付近（男声・ベース上部）がノッチ状に欠けていた。LR2（Q=0.5 +
  // 極性反転）は和がオールパスになる — カットオフちょうどの正弦波でも痩せないこと。
  var crossover = Crossover(cutoff: 250, sampleRate: sampleRate)
  let tone = ToneGenerator.sine(
    frequency: 250, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1
  )
  let (low, high) = crossover.split(tone)
  let sum = zip(low, high).map(+)
  let input = tailRMS(tone, skip: 4_800)
  let recombined = tailRMS(sum, skip: 4_800)
  #expect(abs(recombined - input) / input < 0.05)
}

@Test func theBandsSumFlatAcrossTheSpectrum() {
  // オールパス性はカットオフの一点だけの話ではない。帯域の代表点で和が平坦なこと。
  for frequency in [60.0, 125.0, 250.0, 500.0, 1_000.0, 4_000.0] {
    var crossover = Crossover(cutoff: 250, sampleRate: sampleRate)
    let tone = ToneGenerator.sine(
      frequency: frequency, sampleRate: sampleRate, frameCount: 9_600, amplitude: 1
    )
    let (low, high) = crossover.split(tone)
    let sum = zip(low, high).map(+)
    let input = tailRMS(tone, skip: 4_800)
    let recombined = tailRMS(sum, skip: 4_800)
    #expect(abs(recombined - input) / input < 0.05, "at \(frequency) Hz")
  }
}
