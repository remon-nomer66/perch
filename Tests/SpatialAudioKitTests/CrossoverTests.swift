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
