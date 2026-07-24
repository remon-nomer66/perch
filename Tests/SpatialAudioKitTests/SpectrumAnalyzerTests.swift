import Foundation
import Testing

@testable import SpatialAudioKit

private let sampleRate = 48_000.0

@Test func aSineShowsItsPeakAtTheMatchingBin() {
  let analyzer = SpectrumAnalyzer(size: 1024)
  #expect(analyzer != nil)
  // ビン32ぴったりの周波数（= 32 × 48000 / 1024 Hz）なら、最大ビンは 32 になる。
  let frequency = 32.0 * sampleRate / 1024.0
  let frame = ToneGenerator.sine(
    frequency: frequency, sampleRate: sampleRate, frameCount: 1024, amplitude: 1)
  let magnitudes = analyzer!.magnitudes(frame)
  #expect(magnitudes.count == 512)
  let peak = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] })
  #expect(peak == 32)
  // 振幅1のサインは正規化後およそ 0.5（Hann窓の利得込み）。桁が合っていればよい。
  #expect(magnitudes[32] > 0.3)
}

@Test func silenceYieldsAnAllZeroSpectrum() {
  let analyzer = SpectrumAnalyzer(size: 1024)!
  let magnitudes = analyzer.magnitudes([Float](repeating: 0, count: 1024))
  #expect(magnitudes.count == 512)
  #expect(magnitudes.allSatisfy { $0 == 0 })
}

@Test func aWrongLengthFrameIsRejected() {
  let analyzer = SpectrumAnalyzer(size: 1024)!
  #expect(analyzer.magnitudes([Float](repeating: 0.5, count: 512)).isEmpty)
}

@Test func anInvalidSizeFailsToInitialise() {
  // 2の冪でない・小さすぎるサイズは作れない。
  #expect(SpectrumAnalyzer(size: 1000) == nil)
  #expect(SpectrumAnalyzer(size: 0) == nil)
}
