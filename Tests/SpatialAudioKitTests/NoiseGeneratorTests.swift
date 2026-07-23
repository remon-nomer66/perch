import Foundation
import Testing

@testable import SpatialAudioKit

@Test func whiteNoiseHasTheRequestedLength() {
  #expect(NoiseGenerator.white(frameCount: 256).count == 256)
}

@Test func whiteNoiseStaysWithinTheRequestedAmplitude() {
  let s = NoiseGenerator.white(frameCount: 10_000, amplitude: 0.3)
  #expect(s.allSatisfy { abs($0) <= 0.3 + 1e-6 })
}

@Test func theSameSeedProducesTheSameNoise() {
  // ループ再生で波形が揺れないよう、決定論的であることを固定する。
  let a = NoiseGenerator.white(frameCount: 512, seed: 42)
  let b = NoiseGenerator.white(frameCount: 512, seed: 42)
  #expect(a == b)
}

@Test func differentSeedsProduceDifferentNoise() {
  let a = NoiseGenerator.white(frameCount: 512, seed: 1)
  let b = NoiseGenerator.white(frameCount: 512, seed: 2)
  #expect(a != b)
}

@Test func aZeroFrameRequestIsEmpty() {
  #expect(NoiseGenerator.white(frameCount: 0).isEmpty)
}

@Test func aZeroSeedStillProducesSignal() {
  // 種 0 でも無音（全ゼロ）に張り付かないこと。
  let s = NoiseGenerator.white(frameCount: 256, seed: 0)
  #expect(s.contains { $0 != 0 })
}
