import Foundation
import Testing

@testable import SpatialAudioKit

@Test func sineHasTheRequestedLength() {
  #expect(ToneGenerator.sine(frequency: 440, sampleRate: 48_000, frameCount: 128).count == 128)
}

@Test func sineStartsAtZero() {
  let s = ToneGenerator.sine(frequency: 440, sampleRate: 48_000, frameCount: 16)
  #expect(abs(s[0]) < 1e-6)
}

@Test func sineStaysWithinTheRequestedAmplitude() {
  let s = ToneGenerator.sine(
    frequency: 1_000, sampleRate: 48_000, frameCount: 4_800, amplitude: 0.3
  )
  #expect(s.allSatisfy { abs($0) <= 0.3 + 1e-6 })
}

@Test func nonsenseRequestsReturnEmpty() {
  // 分からない/意味のない要求は空を返す。もっともらしい音で埋めない。
  #expect(ToneGenerator.sine(frequency: 440, sampleRate: 48_000, frameCount: 0).isEmpty)
  #expect(ToneGenerator.sine(frequency: 0, sampleRate: 48_000, frameCount: 100).isEmpty)
  #expect(ToneGenerator.sine(frequency: 440, sampleRate: 0, frameCount: 100).isEmpty)
}
