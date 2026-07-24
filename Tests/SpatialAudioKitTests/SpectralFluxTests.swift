import Foundation
import Testing

@testable import SpatialAudioKit

@Test func risingEnergyProducesFlux() {
  // DC(ビン0)は除外し、残り3ビンの正の増分の平均。
  let flux = SpectralFlux.flux(previous: [0, 0, 0, 0], current: [9, 1, 1, 1])
  #expect(abs(flux - 1.0) < 1e-9)
}

@Test func fallingEnergyIsIgnored() {
  // 半波整流: 減った分は音の立ち上がりではないので数えない。
  let flux = SpectralFlux.flux(previous: [0, 1, 1, 1], current: [0, 0, 0, 0])
  #expect(flux == 0)
}

@Test func aDCOnlyChangeIsNotAnOnset() {
  let flux = SpectralFlux.flux(previous: [0, 0.5, 0.5], current: [5, 0.5, 0.5])
  #expect(flux == 0)
}

@Test func mismatchedSpectraUseTheCommonPrefix() {
  let flux = SpectralFlux.flux(previous: [0, 0], current: [0, 2, 100])
  #expect(abs(flux - 2.0) < 1e-9)
}

@Test func tooShortSpectraYieldZero() {
  #expect(SpectralFlux.flux(previous: [], current: []) == 0)
  #expect(SpectralFlux.flux(previous: [1], current: [1]) == 0)
}

@Test func logCompressionIsZeroAtZeroAndMonotonic() {
  let compressed = SpectralFlux.logCompressed([0, 0.01, 0.1, 0.5])
  #expect(compressed[0] == 0)
  #expect(compressed[1] > 0)
  #expect(compressed[2] > compressed[1])
  #expect(compressed[3] > compressed[2])
}

@Test func logCompressionLiftsQuietSounds() {
  // 対数圧縮の狙い: 10倍の音量差が10倍のフラックス差にならないこと。
  let compressed = SpectralFlux.logCompressed([0.05, 0.5])
  #expect(compressed[1] / compressed[0] < 5)
}
